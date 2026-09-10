#!/usr/bin/python3
"""Experimental offline mover: verify and journal each batch before freeing ext4.

The SQLite manifest must live outside the filesystem being converted. fsremap
handles the later physical block relocation; this module handles file semantics.
"""
import argparse
import base64
import ctypes
import hashlib
import json
import os
import sqlite3
import stat
import subprocess
import time

BUFFER = 4 * 1024**2
BATCH = 64 * 1024**2
SKIP = {b'proc', b'sys', b'dev', b'run', b'tmp', b'old', b'target',
        b'rescue-media', b'var/lib/zfs-on-boot', b'boot/zfs-on-boot',
        b'boot/zfsify-inplace-state', b'boot/efi', b'.zfsify.img',
        b'swapfile', b'swap.img'}


def encode(value):
    return base64.b64encode(value).decode('ascii')


def decode(value):
    return base64.b64decode(value)


def digest(path):
    result = hashlib.sha256()
    with open(path, 'rb', buffering=0) as stream:
        while data := stream.read(BUFFER):
            result.update(data)
    return result.hexdigest()


def metadata(path):
    s = os.lstat(path)
    result = {key: getattr(s, 'st_' + key) for key in
              ('mode', 'uid', 'gid', 'size', 'atime_ns', 'mtime_ns', 'dev', 'ino', 'nlink', 'rdev')}
    result['attrs'] = {encode(os.fsencode(key)): encode(os.getxattr(path, key, follow_symlinks=False))
                       for key in os.listxattr(path, follow_symlinks=False)}
    if stat.S_ISLNK(s.st_mode):
        result['link'] = encode(os.readlink(path))
    return result


def capture(db, source):
    db.execute('CREATE TABLE entries(path BLOB PRIMARY KEY, meta TEXT, digest TEXT, offset INTEGER DEFAULT 0, done INTEGER DEFAULT 0)')
    links = {}

    def visit(relative):
        path = os.path.join(source, relative)
        meta = metadata(path)
        checksum = None
        if not stat.S_ISDIR(meta['mode']) and meta['nlink'] > 1:
            identity = (meta['dev'], meta['ino'])
            if identity in links:
                meta['hardlink'] = encode(links[identity])
            else:
                links[identity] = relative
        if stat.S_ISREG(meta['mode']) and 'hardlink' not in meta:
            checksum = digest(path)
        db.execute('INSERT INTO entries(path,meta,digest) VALUES(?,?,?)',
                   (relative, json.dumps(meta), checksum))
        if stat.S_ISDIR(meta['mode']):
            with os.scandir(path) as children:
                for child in children:
                    rel = os.path.join(relative, child.name)
                    if rel not in SKIP:
                        visit(rel)

    visit(b'')
    db.commit()
    print(f"Manifest saved: {db.execute('SELECT count(*) FROM entries').fetchone()[0]} entries", flush=True)


def apply_metadata(path, meta):
    os.chown(path, meta['uid'], meta['gid'], follow_symlinks=False)
    if not stat.S_ISLNK(meta['mode']):
        os.chmod(path, stat.S_IMODE(meta['mode']))
    for key, value in meta['attrs'].items():
        os.setxattr(path, decode(key), decode(value), follow_symlinks=False)
    os.utime(path, ns=(meta['atime_ns'], meta['mtime_ns']), follow_symlinks=False)


def move(db, source, target, pool):
    root_device = os.stat(source).st_dev
    libc = ctypes.CDLL(None, use_errno=True)
    libc.fallocate.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_longlong, ctypes.c_longlong]

    def release(fd, offset, length):
        if length and libc.fallocate(fd, 3, offset, length):  # KEEP_SIZE | PUNCH_HOLE
            raise OSError(ctypes.get_errno(), 'Cannot release verified source extent')
        os.fsync(fd)

    total = sum(json.loads(meta)['size'] for (meta,) in db.execute(
        'SELECT meta FROM entries WHERE digest IS NOT NULL'))
    moved = sum(offset for (offset,) in db.execute('SELECT offset FROM entries'))
    total_files = files_done = 0
    for encoded, done in db.execute('SELECT meta,done FROM entries'):
        if not stat.S_ISDIR(json.loads(encoded)['mode']):
            total_files += 1
            files_done += done
    print(f'ZFSIFY_START {moved} {total}', flush=True)
    print(f'ZFSIFY_FILES {files_done} {total_files}', flush=True)
    started, initial, last_report = time.monotonic(), moved, 0
    for relative, encoded, checksum, offset, done in db.execute('SELECT * FROM entries ORDER BY rowid'):
        meta = json.loads(encoded)
        src, dst = os.path.join(source, relative), os.path.join(target, relative)
        mode = meta['mode']
        if stat.S_ISDIR(mode):
            os.makedirs(dst, mode=0o700, exist_ok=True)
            continue
        if done and os.path.lexists(dst):
            apply_metadata(dst, meta)
            continue
        if 'hardlink' in meta:
            canonical = os.path.join(target, decode(meta['hardlink']))
            if not os.path.lexists(dst):
                os.link(canonical, dst, follow_symlinks=False)
        elif stat.S_ISREG(mode):
            reclaim = meta['dev'] == root_device
            infd = os.open(src, os.O_RDWR if reclaim else os.O_RDONLY)
            outfd = os.open(dst, os.O_CREAT | os.O_RDWR, 0o600)
            try:
                os.ftruncate(outfd, meta['size'])
                # A committed checkpoint may precede a crash before hole punching.
                if reclaim and offset:
                    release(infd, 0, offset)
                while offset < meta['size']:
                    # ZFS COW metadata can leave obsolete blocks allocated in
                    # the enclosing ext4 image. Reclaim them before headroom
                    # runs out; the temporary loop/DM stack forwards discard.
                    space = os.statvfs(source)
                    if space.f_bavail * space.f_frsize < 1024**3:
                        print('Reclaiming unused ZFS image blocks on ext4...', flush=True)
                        subprocess.run(['zpool', 'trim', '-w', pool], check=True)
                    # Stop before an ENOSPC write can suspend the file-backed
                    # pool. Both filesystems need room for a batch and metadata.
                    for filesystem in (source, target):
                        free = os.statvfs(filesystem)
                        if free.f_bavail * free.f_frsize < 2 * BATCH:
                            raise RuntimeError('Insufficient working space; migration paused before the next batch')
                    end = min(offset + BATCH, meta['size'])
                    position = offset
                    expected = hashlib.sha256()
                    while position < end:
                        data = os.pread(infd, min(BUFFER, end - position), position)
                        if not data:
                            raise RuntimeError(f'Short source read: {src!r}')
                        expected.update(data)
                        if data.strip(b'\0'):
                            written = os.pwrite(outfd, data, position)
                            if written != len(data):
                                raise RuntimeError(f'Short target write: {dst!r}')
                        position += len(data)
                    os.fsync(outfd)
                    actual = hashlib.sha256()
                    position = offset
                    while position < end:
                        data = os.pread(outfd, min(BUFFER, end - position), position)
                        if not data:
                            raise RuntimeError(f'Short verification read: {dst!r}')
                        actual.update(data)
                        position += len(data)
                    if expected.digest() != actual.digest():
                        raise RuntimeError(f'Batch checksum mismatch: {dst!r}')
                    subprocess.run(['zpool', 'sync', pool], check=True)
                    db.execute('UPDATE entries SET offset=? WHERE path=?', (end, relative))
                    db.commit()
                    if reclaim:
                        release(infd, offset, end - offset)
                    moved += end - offset
                    offset = end
                    now = time.monotonic()
                    if now - last_report >= 2:
                        speed = (moved - initial) / max(now - started, 0.001) / 1e6
                        print(f'ZFSIFY_PROGRESS {moved} {total}', flush=True)
                        print(f'ZFSIFY_FILES {files_done} {total_files}', flush=True)
                        print(f'{moved/1e6:,.1f}/{total/1e6:,.1f} MB | {speed:.1f} MB/s | {os.fsdecode(relative)!r}', flush=True)
                        last_report = now
            finally:
                os.close(outfd)
                os.close(infd)
            if digest(dst) != checksum:
                raise RuntimeError(f'Whole-file checksum mismatch: {dst!r}')
        elif stat.S_ISLNK(mode):
            if not os.path.lexists(dst):
                os.symlink(decode(meta['link']), dst)
        elif not os.path.lexists(dst):
            os.mknod(dst, mode, meta['rdev'])
        apply_metadata(dst, meta)
        db.execute('UPDATE entries SET done=1 WHERE path=?', (relative,))
        db.commit()
        files_done += not done
    for relative, encoded in db.execute('SELECT path,meta FROM entries ORDER BY rowid DESC'):
        meta = json.loads(encoded)
        if stat.S_ISDIR(meta['mode']):
            apply_metadata(os.path.join(target, relative), meta)
    subprocess.run(['zpool', 'sync', pool], check=True)
    subprocess.run(['zpool', 'trim', '-w', pool], check=True)
    print(f'ZFSIFY_PROGRESS {moved} {total}', flush=True)
    print(f'ZFSIFY_FILES {files_done} {total_files}', flush=True)


def verify(db, target):
    count = 0
    for relative, encoded, checksum in db.execute('SELECT path,meta,digest FROM entries'):
        meta = json.loads(encoded)
        path = os.path.join(target, relative)
        actual = metadata(path)
        for key in ('mode', 'uid', 'gid', 'mtime_ns', 'attrs'):
            if actual[key] != meta[key]:
                raise RuntimeError(f'Metadata mismatch ({key}): {path!r}')
        if checksum and digest(path) != checksum:
            raise RuntimeError(f'Checksum mismatch: {path!r}')
        if 'link' in meta and actual['link'] != meta['link']:
            raise RuntimeError(f'Symlink mismatch: {path!r}')
        if 'hardlink' in meta and actual['ino'] != os.lstat(os.path.join(target, decode(meta['hardlink']))).st_ino:
            raise RuntimeError(f'Hard-link mismatch: {path!r}')
        count += 1
    print(f'VERIFIED: {count} entries; SHA256, modes, owners, timestamps, ACLs, xattrs and hard links.', flush=True)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=['capture', 'move', 'verify'])
    parser.add_argument('manifest')
    parser.add_argument('source')
    parser.add_argument('target', nargs='?')
    parser.add_argument('--pool', default='rpool')
    args = parser.parse_args()
    db = sqlite3.connect(args.manifest)
    db.execute('PRAGMA synchronous=FULL')
    if args.action == 'capture':
        capture(db, os.fsencode(args.source))
    elif args.action == 'move':
        move(db, os.fsencode(args.source), os.fsencode(args.target), args.pool)
    else:
        verify(db, os.fsencode(args.source))

#!/bin/bash
# Disposable native ARM64 Ubuntu test on an Apple Silicon Mac (QEMU + HVF).
# brew install qemu; python3 must have pycdlib installed (a venv is fine).
set -Eeuo pipefail
[[ $(uname -sm) = 'Darwin arm64' ]]
BASE=$(cd "$(dirname "$0")/.." && pwd)
STATE=$(mktemp -d "${TMPDIR:-/tmp}/zfsify-arm64.XXXXXXXX")
chmod 700 "$STATE"
PORT=${ARM_TEST_SSH_PORT:-22292}
QEMU=$(command -v qemu-system-aarch64)
FIRMWARE=$(cd "$(dirname "$QEMU")/../share/qemu" && pwd)
SSH=(ssh -F /dev/null -p "$PORT" -i "$STATE/key" -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile="$STATE/known_hosts" -o ConnectTimeout=5 -o ServerAliveInterval=5 -o ServerAliveCountMax=2 root@127.0.0.1)
SCP=(scp -F /dev/null -P "$PORT" -i "$STATE/key" -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile="$STATE/known_hosts")
cleanup() {
    code=$?
    trap - EXIT
    if [[ ${KEEP_TEST_VM:-0} != 1 ]]; then
        if [[ -f $STATE/qemu.pid ]]; then
            pid=$(cat "$STATE/qemu.pid")
            if ps -p "$pid" -o command= | grep -Fq "$STATE/root.qcow2"; then
                kill "$pid"
                for _ in {1..30}; do kill -0 "$pid" 2>/dev/null || break; sleep 1; done
                if kill -0 "$pid" 2>/dev/null; then
                    echo "VM still running; retained $STATE" >&2
                    exit 1
                fi
            fi
        fi
        rm -f "$STATE"/{root.qcow2,ubuntu.img,seed.iso,vars.fd,key,key.pub}
    fi
    echo "Evidence directory: $STATE"
    exit "$code"
}
trap cleanup EXIT
python3 -c 'import pycdlib'
ssh-keygen -q -t ed25519 -N '' -C zfsify-arm64-test -f "$STATE/key"
URL=https://cloud-images.ubuntu.com/noble/current
curl -fsSL --retry 3 "$URL/noble-server-cloudimg-arm64.img" -o "$STATE/ubuntu.img"
curl -fsSL --retry 3 "$URL/SHA256SUMS" -o "$STATE/SHA256SUMS"
python3 - "$STATE" <<'PY'
from pathlib import Path
import hashlib, io, pycdlib, sys
p = Path(sys.argv[1])
expected = next(line.split()[0] for line in (p/'SHA256SUMS').read_text().splitlines()
                if line.split()[-1].lstrip('*') == 'noble-server-cloudimg-arm64.img')
with (p/'ubuntu.img').open('rb') as stream:
    digest = hashlib.sha256()
    for chunk in iter(lambda: stream.read(4 * 1024**2), b''):
        digest.update(chunk)
    assert digest.hexdigest() == expected
iso = pycdlib.PyCdlib()
iso.new(interchange_level=3, joliet=3, vol_ident='cidata')
user = '#cloud-config\ndisable_root: false\nssh_pwauth: false\nusers:\n  - name: root\n    ssh_authorized_keys:\n      - ' + (p/'key.pub').read_text().strip() + '\n'
for name, value in [('user-data', user), ('meta-data', 'instance-id: zfsify-arm64-test\nlocal-hostname: zfsify-arm64-test\n')]:
    data = value.encode()
    iso.add_fp(io.BytesIO(data), len(data), iso_path='/'+name.upper().replace('-', '_')+';1', joliet_path='/'+name)
iso.write(str(p/'seed.iso'))
iso.close()
PY
cp "$FIRMWARE/edk2-arm-vars.fd" "$STATE/vars.fd"
qemu-img create -f qcow2 -F qcow2 -b "$STATE/ubuntu.img" "$STATE/root.qcow2" 25G
"$QEMU" -machine virt -cpu host -accel hvf -smp 2 -m 1024 \
    -drive "if=pflash,format=raw,readonly=on,file=$FIRMWARE/edk2-aarch64-code.fd" \
    -drive "if=pflash,format=raw,file=$STATE/vars.fd" \
    -drive "if=none,file=$STATE/root.qcow2,format=qcow2,id=os" -device virtio-blk-pci,drive=os \
    -drive "if=none,file=$STATE/seed.iso,format=raw,id=seed,readonly=on" -device virtio-blk-pci,drive=seed \
    -netdev "user,id=net0,hostfwd=tcp:127.0.0.1:$PORT-:22" -device virtio-net-pci,netdev=net0,romfile= \
    -display none -serial "file:$STATE/serial.log" -monitor "unix:$STATE/monitor.sock,server,nowait" \
    -object rng-random,id=rng0,filename=/dev/urandom -device virtio-rng-pci,rng=rng0 \
    -daemonize -pidfile "$STATE/qemu.pid" 2>"$STATE/qemu.log"
for _ in {1..60}; do "${SSH[@]}" true 2>/dev/null && break; sleep 2; done
"${SSH[@]}" 'cloud-init status --wait'
python3 "$BASE/scripts/package.py"
"${SCP[@]}" "$BASE/reformat.sh" "$BASE/scripts/"{setup-fixture.sh,setup-inplace-fill.py,verify.sh,verify-preserved.sh} root@127.0.0.1:/root/
"${SSH[@]}" 'bash /root/setup-fixture.sh preserve && python3 /root/setup-inplace-fill.py' | tee "$STATE/input.txt"
"${SSH[@]}" 'systemd-run --unit=zfsify-test bash -c "cat /root/reformat.sh | sh -s -- --inplace"'
ready=0
for _ in {1..360}; do
    if "${SSH[@]}" 'test -f /etc/zfs-on-boot-installed && test "$(findmnt -no FSTYPE /)" = zfs' 2>/dev/null; then ready=1; break; fi
    sleep 10
done
[[ $ready = 1 ]]
"${SSH[@]}" 'ZFSIFY_SKIP_DO_METADATA=1 bash /root/verify.sh && bash /root/verify-preserved.sh && zpool scrub rpool && zpool wait -t scrub rpool && zpool status && zpool status rpool | grep -q "errors: No known data errors"' | tee "$STATE/verification.txt"
"${SCP[@]}" root@127.0.0.1:/var/log/zfs-on-boot/install.log "$STATE/install.log"
old_boot=$("${SSH[@]}" cat /proc/sys/kernel/random/boot_id)
"${SSH[@]}" systemctl reboot || true
ready=0
for _ in {1..60}; do
    new_boot=$("${SSH[@]}" cat /proc/sys/kernel/random/boot_id 2>/dev/null || true)
    if [[ -n $new_boot && $new_boot != "$old_boot" ]]; then ready=1; break; fi
    sleep 3
done
[[ $ready = 1 ]]
"${SSH[@]}" 'ZFSIFY_SKIP_DO_METADATA=1 bash /root/verify.sh && bash /root/verify-preserved.sh' | tee "$STATE/reboot.txt"
"${SSH[@]}" systemctl poweroff || true
echo 'Native ARM64 in-place root conversion and subsequent reboot passed.'

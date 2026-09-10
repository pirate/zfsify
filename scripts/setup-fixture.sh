#!/bin/bash
# Test data only; run inside a disposable VM before conversion.
set -Eeuo pipefail
case ${1:-preserve} in
preserve)
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y -qq acl attr
    useradd -m -s /bin/bash migrationtest
    mkdir -p /home/migrationtest/.ssh
    cp /root/.ssh/authorized_keys /home/migrationtest/.ssh/authorized_keys
    chown -R migrationtest:migrationtest /home/migrationtest
    printf 'retained config\n' > /etc/zfsify-test.conf
    mkdir /root/migration-fixture
    dd if=/dev/urandom of=/root/migration-fixture/random.bin bs=1M count=512 status=none
    ln /root/migration-fixture/random.bin /root/migration-fixture/hardlink.bin
    truncate -s 2G /root/migration-fixture/sparse.bin
    printf sparse-tail | dd of=/root/migration-fixture/sparse.bin bs=1 seek=2147483600 conv=notrunc status=none
    setfattr -n user.zfsify -v retained /root/migration-fixture/random.bin
    setfacl -m u:migrationtest:r /root/migration-fixture/random.bin
    sha256sum /root/migration-fixture/* > /root/migration-fixture.SHA256SUMS
    cp /etc/passwd /root/passwd.before
    cp /etc/shadow /root/shadow.before
    sha256sum /etc/ssh/ssh_host_* > /root/hostkeys.before
    ;;
erase)
    useradd -m -s /bin/bash erasetest
    mkdir -p /home/erasetest/.ssh
    cp /root/.ssh/authorized_keys /home/erasetest/.ssh/authorized_keys
    chown -R erasetest:erasetest /home/erasetest
    chmod 700 /home/erasetest/.ssh
    chmod 600 /home/erasetest/.ssh/authorized_keys
    printf 'keep configuration\n' > /etc/zfsify-erase-test.conf
    printf 'keep small priority file\n' > /home/erasetest/keep-me
    printf 'keep complete SSH config\n' > /home/erasetest/.ssh/config
    cp /etc/passwd /etc/zfsify-passwd.before
    cp /etc/shadow /etc/zfsify-shadow.before
    sha256sum /etc/ssh/ssh_host_* /home/erasetest/.ssh/authorized_keys > /etc/zfsify-keys.before
    read -r size used < <(df -B1 --output=size,used / | tail -1)
    fallocate -l "$((size * 55 / 100 - used))" /root/space-gate
    ;;
*) exit 2 ;;
esac

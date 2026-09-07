#!/bin/bash
# All runtime checks run on a disposable DigitalOcean Droplet.
# Requires DIGITALOCEAN_TOKEN, Python 3, curl, and OpenSSH on the controller.
set -Eeuo pipefail
BASE=$(cd "$(dirname "$0")/.." && pwd)
STATE=$(mktemp -d "${TMPDIR:-/tmp}/zfs-on-boot-e2e.XXXXXXXX")
chmod 700 "$STATE"
IP=
MODE=${1:-preserve}
case "$MODE" in
    preserve) INSTALL_ARGS=; FIXTURE_CHECK=verify-preserved.sh ;;
    erase) INSTALL_ARGS=--erase; FIXTURE_CHECK=verify-erased.sh ;;
    *) echo 'Usage: scripts/do-e2e.sh [preserve|erase]' >&2; exit 2 ;;
esac
SSH=(ssh -F /dev/null -i "$STATE/key" -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile="$STATE/known_hosts" -o ConnectTimeout=10 -o ServerAliveInterval=5 -o ServerAliveCountMax=3)
SCP=(scp -F /dev/null -i "$STATE/key" -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile="$STATE/known_hosts")
cleanup() {
    code=$?
    trap - EXIT
    if [[ ${KEEP_TEST_DROPLET:-0} = 1 ]]; then
        echo "Retained test resources and SSH key in $STATE; destroy them with scripts/do-test.py."
    elif [[ -f $STATE/resources.json ]]; then
        if python3 "$BASE/scripts/do-test.py" destroy --state "$STATE/resources.json"; then
            rm -f "$STATE/key" "$STATE/key.pub"
        else
            echo "Cleanup failed. Resource IDs and SSH key remain in $STATE." >&2
            code=1
        fi
    fi
    echo "Evidence directory: $STATE"
    exit "$code"
}
trap cleanup EXIT
ssh-keygen -q -t ed25519 -N '' -C zfs-on-boot-e2e -f "$STATE/key"
python3 "$BASE/scripts/package.py"
python3 "$BASE/scripts/do-test.py" create --state "$STATE/resources.json" --key-file "$STATE/key.pub"
for attempt in {1..60}; do
    python3 "$BASE/scripts/do-test.py" status --state "$STATE/resources.json" > "$STATE/status.json"
    IP=$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(next((n["ip_address"] for n in d["networks"]["v4"] if n["type"]=="public"),""))' "$STATE/status.json")
    if [[ -n $IP ]] && "${SSH[@]}" "root@$IP" true 2>/dev/null; then break; fi
    sleep 5
done
[[ -n $IP ]]
"${SSH[@]}" "root@$IP" 'cloud-init status --wait; mkdir -p /root/zfs-on-boot-source'
"${SCP[@]}" "$BASE/scripts/setup-fixture.sh" "$BASE/scripts/$FIXTURE_CHECK" "root@$IP:/root/"
"${SSH[@]}" "root@$IP" "bash /root/setup-fixture.sh $MODE"
"${SCP[@]}" "$BASE/dist/install.sh" "root@$IP:/root/zfs-on-boot-source/install.sh"
"${SSH[@]}" "root@$IP" 'systemd-run --unit=zfs-on-boot-source --collect python3 -m http.server 8765 --bind 127.0.0.1 --directory /root/zfs-on-boot-source'
# Wait for the test HTTP server. It runs on the DO Droplet, not the controller.
"${SSH[@]}" "root@$IP" 'for i in $(seq 1 30); do curl -fsS -o /dev/null http://127.0.0.1:8765/install.sh && exit 0; sleep 1; done; exit 1'
"${SSH[@]}" "root@$IP" "systemd-run --unit=zfs-on-boot-stage --collect /bin/bash -o pipefail -c 'curl -fsSL http://127.0.0.1:8765/install.sh | sh -s -- $INSTALL_ARGS'"
ready=0
for attempt in {1..180}; do
    if "${SSH[@]}" "root@$IP" 'test -f /etc/zfs-on-boot-installed && test "$(findmnt -n -o FSTYPE /)" = zfs' 2>/dev/null; then ready=1; break; fi
    sleep 10
done
[[ $ready = 1 ]]
"${SCP[@]}" "$BASE/scripts/verify.sh" "root@$IP:/root/zfs-on-boot-verify.sh"
"${SSH[@]}" "root@$IP" 'bash /root/zfs-on-boot-verify.sh' | tee "$STATE/verification.txt"
"${SCP[@]}" "$BASE/scripts/$FIXTURE_CHECK" "root@$IP:/root/"
"${SSH[@]}" "root@$IP" "bash /root/$FIXTURE_CHECK" | tee "$STATE/fixture-verification.txt"
"${SCP[@]}" "root@$IP:/var/log/zfs-on-boot/install.log" "$STATE/install.log"
OLD_BOOT=$("${SSH[@]}" "root@$IP" 'cat /proc/sys/kernel/random/boot_id')
"${SSH[@]}" "root@$IP" 'systemctl reboot' || true
ready=0
for attempt in {1..60}; do
    NEW_BOOT=$("${SSH[@]}" "root@$IP" 'cat /proc/sys/kernel/random/boot_id' 2>/dev/null || true)
    if [[ -n $NEW_BOOT && $NEW_BOOT != "$OLD_BOOT" ]]; then ready=1; break; fi
    sleep 5
done
[[ $ready = 1 ]]
"${SSH[@]}" "root@$IP" 'bash /root/zfs-on-boot-verify.sh' | tee "$STATE/verification-after-reboot.txt"
echo 'One-command installation and subsequent reboot passed on DigitalOcean.'

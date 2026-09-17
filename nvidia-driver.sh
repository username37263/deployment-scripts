#!/bin/bash
# Ubuntu 24.04 amd64 test installer. Launched by infrastructure-software.service.
# No account credentials or site-specific configuration belong in this file.
set -Eeuo pipefail
umask 077
STATE=/var/lib/infrastructure-software
mkdir -p "$STATE"
exec 9>"$STATE/lock"
flock -n 9 || exit 0
report() { /usr/local/lib/infrastructure-software/report.py "$1" "${2:-}" || true; }
fail() { trap - ERR; printf '%s\n' "$1" > "$STATE/failed"; report failed "$1"; exit 1; }
trap 'fail "Driver setup failed during ${phase:-startup}. See journalctl -u infrastructure-software."' ERR
if [[ -f "$STATE/done" ]]; then report complete 'NVIDIA driver verified'; exit 0; fi
if [[ -f "$STATE/failed" ]]; then report failed "$(cat "$STATE/failed")"; exit 1; fi
phase=preflight
source /etc/os-release
[[ "$ID" == ubuntu && "$VERSION_ID" == 24.04 && "$(uname -m)" == x86_64 ]] || fail 'This test supports Ubuntu 24.04 on x86_64 only.'
boot_id=$(cat /proc/sys/kernel/random/boot_id)
if [[ -f "$STATE/reboot-from" ]]; then
    [[ "$(cat "$STATE/reboot-from")" != "$boot_id" ]] || fail 'A reboot was requested but has not happened. Reboot once, then clear the failed marker and restart the service.'
    phase=verification
    report verifying 'Checking GPUs after reboot'
    expected=$(cat "$STATE/gpu-count")
    for attempt in {1..30}; do
        if nvidia-smi --query-gpu=uuid --format=csv,noheader > "$STATE/gpus" 2>/dev/null; then
            actual=$(wc -l < "$STATE/gpus")
            if [[ "$actual" -eq "$expected" && "$actual" -gt 0 ]]; then
                touch "$STATE/done"
                report complete 'NVIDIA driver loaded and all detected GPUs verified'
                exit 0
            fi
        fi
        sleep 10
    done
    fail 'NVIDIA verification failed after reboot: not all detected GPUs respond to nvidia-smi.'
fi
report preparing 'Checking operating system and GPUs'
count=0
for dev in /sys/bus/pci/devices/*; do
    if [[ "$(cat "$dev/vendor")" == 0x10de && "$(cat "$dev/class")" == 0x03* ]]; then count=$((count+1)); fi
done
[[ "$count" -gt 0 ]] || fail 'No NVIDIA GPUs detected.'
printf '%s\n' "$count" > "$STATE/gpu-count"
phase=packages
export DEBIAN_FRONTEND=noninteractive
apt-get -o DPkg::Lock::Timeout=600 update
apt-get -o DPkg::Lock::Timeout=600 install -y ubuntu-drivers-common mokutil "linux-headers-$(uname -r)"
if mokutil --sb-state 2>/dev/null | grep -qi 'SecureBoot enabled'; then
    fail 'Secure Boot is enabled. This test requires an operator-approved signed-driver setup before automatic installation.'
fi
# Select only an open-kernel driver advertised as compatible by Ubuntu.
# Blackwell requires recent open kernel modules. Do not add an untrusted PPA.
package=$(ubuntu-drivers list | awk '{print $1}' | grep -E '^nvidia-driver-[0-9]+(-server)?-open$' | awk -F- '$3 >= 570' | sort -V | tail -1) || true
[[ -n "$package" ]] || fail 'No compatible NVIDIA open driver (570 or newer) is available in the configured Ubuntu repositories.'
printf '%s\n' "$package" > "$STATE/package"
report installing "Installing $package"
apt-get -o DPkg::Lock::Timeout=600 install -y "$package"
phase=reboot
printf '%s\n' "$boot_id" > "$STATE/reboot-from"
report rebooting 'Restarting to load the NVIDIA driver'
sync
systemctl reboot

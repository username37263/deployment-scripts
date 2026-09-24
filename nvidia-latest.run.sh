#!/usr/bin/env bash
# Latest NVIDIA Linux x86_64 .run installer for headless Ubuntu 22.04/24.04.
# Run as root. Each explicit invocation resolves NVIDIA's latest.txt afresh.
# Reboots automatically (up to two); --resume is reserved for its systemd unit.
set -Eeuo pipefail
umask 077
STATE=/var/lib/nvidia-latest-run
SELF=/usr/local/sbin/nvidia-latest-run
UNIT=nvidia-latest-run.service
TIMER=nvidia-latest-run.timer
BASE=https://download.nvidia.com/XFree86/Linux-x86_64
[[ $EUID == 0 ]] || { echo 'ERROR: run with sudo'; exit 1; }
mkdir -p "$STATE"
chmod 700 "$STATE"
exec 9>"$STATE/lock"
flock -n 9 || { echo 'ERROR: another installer is running'; exit 1; }
report() {
    echo "[$(date -Is)] $1: ${2:-}"
    if [[ -x /usr/local/lib/infrastructure-software/report.py ]]; then
        /usr/local/lib/infrastructure-software/report.py "$1" "${2:-}" || true
    fi
}
phase() { printf '%s\n' "$1" > "$STATE/phase.tmp"; mv "$STATE/phase.tmp" "$STATE/phase"; }
fail() { trap - ERR; phase failed; report failed "$1"; exit 1; }
trap 'fail "Installation failed near line $LINENO. Check journalctl -u nvidia-latest-run and /var/log/nvidia-installer.log."' ERR
# Scope proxy recovery to this installer; keep the host APT configuration intact.
APT_DIRECT=false
apt_run() {
    local opts=(-o DPkg::Lock::Timeout=600 -o Acquire::Retries=3 -o Acquire::Languages=none -o APT::Update::Error-Mode=any)
    if $APT_DIRECT; then opts+=(-o Acquire::http::Proxy=DIRECT -o Acquire::https::Proxy=DIRECT); fi
    if apt-get "${opts[@]}" "$@"; then return 0; fi
    if ! $APT_DIRECT; then
        report preparing 'Package download failed; retrying directly without the package proxy'
        APT_DIRECT=true
        if apt-get "${opts[@]}" -o Acquire::http::Proxy=DIRECT -o Acquire::https::Proxy=DIRECT "$@"; then return 0; fi
    fi
    fail "ERROR: Ubuntu package $1 failed. Check repository/proxy connectivity and journalctl -u nvidia-latest-run."
}
fetch() { curl --fail --silent --show-error --location --proto '=https' --proto-redir '=https' --retry 3 --connect-timeout 20 --max-time 1800 "$@"; }
gpu_count() {
    local n=0 d
    for d in /sys/bus/pci/devices/*; do
        if [[ $(cat "$d/vendor") == 0x10de && $(cat "$d/class") == 0x03* ]]; then n=$((n+1)); fi
    done
    printf '%s\n' "$n"
}
reboot_once() {
    local marker=$1 next=$2 boot
    boot=$(cat /proc/sys/kernel/random/boot_id)
    [[ ! -f "$STATE/$marker" ]] || fail 'Reboot limit reached; operator review required.'
    printf '%s\n' "$boot" > "$STATE/$marker"
    phase "$next"
    report rebooting "$3"
    sync
    systemctl reboot
    exit 0
}
source /etc/os-release
[[ $ID == ubuntu && $VERSION_ID =~ ^(22.04|24.04)$ && $(uname -m) == x86_64 ]] || fail 'Supported: headless Ubuntu 22.04/24.04 x86_64.'
[[ $(gpu_count) -gt 0 ]] || fail 'No NVIDIA GPUs detected.'
if [[ ${1:-} != --resume ]]; then
    [[ $# == 0 ]] || fail 'Usage: sudo bash nvidia-latest.run.sh'
    current=$(cat "$STATE/phase" 2>/dev/null || true)
    case "$current" in preparing|installing|after-nouveau|verifying) echo 'ERROR: an installation is pending. Inspect the service before starting another.'; exit 1;; esac
    command -v curl >/dev/null || { apt_run update; DEBIAN_FRONTEND=noninteractive apt_run install -y curl ca-certificates; }
    metadata=$(fetch "$BASE/latest.txt")
    read -r version relative extra <<< "$metadata"
    [[ $version =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ && $relative == "$version/NVIDIA-Linux-x86_64-$version.run" && -z ${extra:-} ]] || fail 'Unexpected NVIDIA latest.txt format; refusing download.'
    [[ ${version%%.*} -ge 570 ]] || fail 'Latest driver is too old for the Blackwell test hardware.'
    # No distro-managed driver is removed automatically, and running workloads are never killed.
    distro=$(dpkg-query -W -f='${binary:Package} ${db:Status-Abbrev}\n' '*nvidia*' 2>/dev/null | awk '$2 == "ii" && $1 ~ /^(nvidia-driver|nvidia-open|nvidia-dkms|linux-modules-nvidia|libnvidia-compute)([-:]|$)/ {print $1}' || true)
    [[ -z $distro ]] || fail 'A distribution-packaged NVIDIA driver is installed. Remove it deliberately before switching to a .run install.'
    if command -v nvidia-smi >/dev/null; then
        active=$(nvidia-smi --query-compute-apps=pid --format=csv,noheader 2>/dev/null) || fail 'Existing driver cannot be queried; review its state before upgrading.'
        [[ -z $active ]] || fail 'GPU workloads are running. Stop them before updating the driver.'
    fi
    systemctl is-active --quiet display-manager && fail 'Stop the display manager before installing on this headless server.'
    if command -v mokutil >/dev/null && mokutil --sb-state 2>/dev/null | grep -qi 'SecureBoot enabled'; then
        fail 'Secure Boot requires a signed-module workflow; this installer will not disable it.'
    fi
    install -m 700 "$(readlink -f "$0")" "$SELF.new"
    mv "$SELF.new" "$SELF"
    printf '%s\n' "$version" > "$STATE/version"
    gpu_count > "$STATE/expected-gpus"
    rm -f "$STATE/nouveau-reboot" "$STATE/driver-reboot"
    cat > /etc/systemd/system/$UNIT <<'UNIT'
[Unit]
Description=Latest NVIDIA runfile driver installation and verification
Wants=network-online.target
After=network-online.target cloud-final.service
[Service]
Type=oneshot
ExecStart=/usr/local/sbin/nvidia-latest-run --resume
TimeoutStartSec=infinity
UNIT
    cat > /etc/systemd/system/$TIMER <<'TIMER'
[Unit]
Description=Resume NVIDIA installer after boot
[Timer]
OnBootSec=30s
Unit=nvidia-latest-run.service
[Install]
WantedBy=timers.target
TIMER
    chmod 644 /etc/systemd/system/$UNIT /etc/systemd/system/$TIMER
    systemctl disable "$UNIT" 2>/dev/null || true
    phase preparing
    systemctl daemon-reload
    systemctl enable "$TIMER"
    systemctl reset-failed "$UNIT" || true
    flock -u 9
    systemctl start --no-block "$UNIT"
    echo "Scheduled NVIDIA $version. Follow: sudo journalctl -fu $UNIT"
    exit 0
fi
version=$(cat "$STATE/version")
current=$(cat "$STATE/phase")
case "$current" in complete) exit 0;; failed) echo 'Previous attempt failed; explicit invocation is required to retry.'; exit 1;; esac
if [[ $current == preparing ]]; then
    report preparing "Preparing NVIDIA $version for $(cat "$STATE/expected-gpus") GPUs"
    export DEBIAN_FRONTEND=noninteractive
    apt_run update
    apt_run install -y build-essential dkms curl ca-certificates mokutil pkg-config libglvnd-dev "linux-headers-$(uname -r)"
    if mokutil --sb-state 2>/dev/null | grep -qi 'SecureBoot enabled'; then fail 'Secure Boot enabled; signed-module setup required.'; fi
    compiler=$(sed -nE 's/.*gcc-([0-9]+).*/\1/p' /proc/version)
    if [[ -n $compiler ]]; then
        apt_run install -y "gcc-$compiler"
        printf '%s\n' "/usr/bin/gcc-$compiler" > "$STATE/compiler"
    else
        command -v gcc > "$STATE/compiler"
    fi
    file=NVIDIA-Linux-x86_64-$version.run
    report downloading "Downloading and checking NVIDIA $version"
    fetch "$BASE/$version/$file.sha256sum" -o "$STATE/checksum"
    expected=$(awk 'NR==1 {print $1}' "$STATE/checksum")
    [[ $expected =~ ^[a-fA-F0-9]{64}$ ]] || fail 'Invalid upstream SHA-256 checksum.'
    if [[ ! -f $STATE/driver.run ]] || [[ $(sha256sum "$STATE/driver.run" | cut -d' ' -f1) != "$expected" ]]; then
        fetch "$BASE/$version/$file" -o "$STATE/driver.run.partial"
        printf '%s  %s\n' "$expected" "$STATE/driver.run.partial" | sha256sum --check -
        mv "$STATE/driver.run.partial" "$STATE/driver.run"
    fi
    bash "$STATE/driver.run" --check
    printf 'blacklist nouveau\noptions nouveau modeset=0\n' > /etc/modprobe.d/nvidia-latest-disable-nouveau.conf
    update-initramfs -u
    if [[ -d /sys/module/nouveau ]]; then reboot_once nouveau-reboot after-nouveau 'Disabling Nouveau before NVIDIA installation'; fi
    phase installing
    current=installing
fi
if [[ $current == after-nouveau ]]; then
    [[ $(cat "$STATE/nouveau-reboot") != $(cat /proc/sys/kernel/random/boot_id) ]] || fail 'Expected a reboot before resuming.'
    [[ ! -d /sys/module/nouveau ]] || fail 'Nouveau is still loaded after reboot; refusing a reboot loop.'
    phase installing
    current=installing
fi
if [[ $current == installing ]]; then
    report installing "Installing NVIDIA $version open kernel driver with DKMS"
    export CC="$(cat "$STATE/compiler")"
    # Limit parallel compilation even on very large servers.
    bash "$STATE/driver.run" --silent --dkms --kernel-module-type=open --no-opengl-files --concurrency-level=16
    reboot_once driver-reboot verifying 'Rebooting to verify the installed NVIDIA driver'
fi
if [[ $current == verifying ]]; then
    [[ $(cat "$STATE/driver-reboot") != $(cat /proc/sys/kernel/random/boot_id) ]] || fail 'Expected a reboot before driver verification.'
    report verifying "Verifying NVIDIA $version and every detected GPU"
    expected=$(cat "$STATE/expected-gpus")
    [[ $(gpu_count) == "$expected" ]] || fail 'GPU inventory changed during installation; operator review required.'
    good=false
    for attempt in {1..30}; do
        if nvidia-smi --query-gpu=driver_version --format=csv,noheader > "$STATE/versions" 2>/dev/null; then
            if [[ $(wc -l < "$STATE/versions") -eq $expected && $(sort -u "$STATE/versions") == "$version" ]]; then good=true; break; fi
        fi
        sleep 10
    done
    $good || fail 'Not all GPUs responded with the expected driver after reboot.'
    modinfo -F license nvidia | grep -q 'Dual MIT/GPL' || fail 'Open kernel module was not loaded.'
    dkms status > "$STATE/dkms-status"
    grep -F "$version" "$STATE/dkms-status" | grep -F "$(uname -r)" | grep -q installed || fail 'DKMS registration for the running kernel is missing.'
    nvidia-smi --query-gpu=index,name,driver_version,memory.total,pci.bus_id --format=csv | tee "$STATE/verified-gpus.csv"
    phase complete
    report complete "NVIDIA $version verified on $expected GPUs"
    systemctl disable "$TIMER"
fi

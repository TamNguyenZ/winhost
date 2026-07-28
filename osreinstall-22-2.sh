#!/bin/bash
# ============================================================================
# OS Reinstaller — Stage 1: Host-side Installer Script
# ============================================================================
# This script runs on the CURRENT live OS (Debian/Ubuntu VPS, root required).
# It downloads an OS image, writes a GRUB boot entry, and reboots into
# a generic initramfs that writes the image to disk.
#
# Usage:
#   bash osreinstall.sh --image-url https://example.com/debian12.raw.zst
#   bash osreinstall.sh --image-url https://example.com/debian12.raw.zst --disk /dev/vda
# ============================================================================

set -euo pipefail
export LANG=C
export PATH="/usr/sbin:/usr/bin:/sbin:/bin:$PATH"

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
readonly TOOL_NAME="osreinstall"
readonly GRUB_MENU_ID="osreinstall"
readonly GRUB_MENU_TITLE="OS Reinstaller"
# Data (kernel/initrd/disk image) is stored OUTSIDE /boot on purpose:
# many VPS hosts have a tiny dedicated /boot partition (a few hundred MB),
# while the root filesystem (/) usually has much more free space. Storing
# multi-GB images under /boot causes "No space left on device" even when
# `df -h /` shows plenty of room. GRUB's `search --file` locates the file
# by scanning all partitions, so it doesn't need to live under /boot.
readonly STAGE2_DIR="/osreinstall-data"
readonly STAGE2_INITRD="${STAGE2_DIR}/osreinstall-initrd.img"
readonly STAGE2_KERNEL="${STAGE2_DIR}/osreinstall-vmlinuz"
readonly STAGE2_IMAGE="${STAGE2_DIR}/osreinstall-disk.img"
readonly STAGE2_IMAGE_CHECKSUM="${STAGE2_DIR}/osreinstall-disk.img.sha256"
readonly STAGE2_IMAGE_SIZE="${STAGE2_DIR}/osreinstall-disk.img.size"
# Relative path used inside GRUB (relative to whatever partition holds it)
readonly STAGE2_GRUB_REL="${STAGE2_DIR#/}"
readonly LOGFILE="/var/log/osreinstall-stage1.log"

# Color helpers
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly CYAN='\033[0;36m'
readonly NC='\033[0m' # No Color

log()        { echo -e "$*" | tee -a "$LOGFILE"; }
log_info()   { log "[$(date '+%H:%M:%S')] [INFO]  $*"; }
log_warn()   { log "${YELLOW}[$(date '+%H:%M:%S')] [WARN]  $*${NC}"; }
log_error()  { log "${RED}[$(date '+%H:%M:%S')] [ERROR] $*${NC}"; }
log_success(){ log "${GREEN}[$(date '+%H:%M:%S')] [OK]    $*${NC}"; }
banner()     { log "${CYAN}=== $* ===${NC}"; }
die()        { log_error "$@"; exit 1; }

# ---------------------------------------------------------------------------
# Parse command-line arguments
# ---------------------------------------------------------------------------
IMAGE_URL=""
TARGET_DISK=""
DRY_RUN=false
FORCE_BIOS=false
NO_REBOOT=false
KERNEL_URL=""

show_usage() {
    cat <<EOF
Usage: $0 --image-url <URL> [--disk <DEVICE>] [--dry-run] [--force-bios] [--no-reboot]

Options:
  --image-url <URL>   Direct HTTP/HTTPS URL to the OS disk image
                      Supported formats: .raw, .raw.gz, .raw.zst, .img, .img.gz
  --disk <DEVICE>     Target disk device (e.g. /dev/sda, /dev/vda)
                      If omitted, auto-selects the largest writable disk
  --dry-run           Validate everything but do not write to disk or reboot
  --force-bios        Force BIOS/legacy boot mode even on UEFI hosts
                      Use this if your OS image is MBR/BIOS-formatted but
                      host firmware is UEFI. Requires CSM support.
  --no-reboot         Do all preparation but do NOT reboot (for testing)
  --kernel-url <URL>  Use a specific kernel from URL instead of host kernel.
                      Recommended for Windows images where host kernel
                      may lack virtio drivers.
                      Example: --kernel-url https://deb.debian.org/debian/pool/main/l/linux/vmlinuz-6.1.0-10-amd64
  --help              Show this help message

Examples:
  $0 --image-url https://example.com/debian12.raw.zst
  $0 --image-url https://example.com/win2022.img --disk /dev/vda --force-bios
EOF
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --image-url) IMAGE_URL="$2"; shift 2 ;;
        --disk)      TARGET_DISK="$2"; shift 2 ;;
        --dry-run)   DRY_RUN=true; shift ;;
        --force-bios) FORCE_BIOS=true; shift ;;
        --kernel-url) KERNEL_URL="$2"; shift 2 ;;
        --help)      show_usage ;;
        -h)          show_usage ;;
        *)           die "Unknown option: $1. Use --help for usage." ;;
    esac
done

if [[ -z "$IMAGE_URL" ]]; then
    die "Missing --image-url. Use --help for usage."
fi

# ---------------------------------------------------------------------------
# Privilege check
# ---------------------------------------------------------------------------
if [[ "$(id -u)" != "0" ]]; then
    die "This script must run as root. Try: sudo bash $0 ..."
fi

# ---------------------------------------------------------------------------
# Init logging
# ---------------------------------------------------------------------------
mkdir -p "$(dirname "$LOGFILE")"
:> "$LOGFILE"

# ---------------------------------------------------------------------------
# Create data directory (on root fs, NOT /boot — see comment near STAGE2_DIR)
# ---------------------------------------------------------------------------
mkdir -p "$STAGE2_DIR"

log_info "OS Reinstaller Stage 1 starting"
log_info "Image URL: $IMAGE_URL"
log_info "Target disk: ${TARGET_DISK:-auto-detect}"
log_info "Dry run: $DRY_RUN"

# ---------------------------------------------------------------------------
# PHASE 1: Environment validation
# ---------------------------------------------------------------------------
banner "Phase 1: Environment check"

# 1a. Check bash version
if [[ -z "${BASH_VERSION:-}" ]]; then
    die "This script requires bash."
fi

# 1b. Check architecture (x86_64 only for now)
ARCH=$(uname -m)
if [[ "$ARCH" != "x86_64" ]]; then
    die "Unsupported architecture: $ARCH. Only x86_64 is supported."
fi
log_info "Architecture: $ARCH"

# 1c. Reject container environments (but allow all real VMs: KVM, VMware, Hyper-V, Xen)
if [[ -f /.dockerenv ]]; then
    die "Running inside Docker container. This tool requires a real OS or VM."
fi
if grep -qE '(docker|containerd|kubepods)' /proc/1/cgroup 2>/dev/null; then
    die "Running in Docker/containerd container. This tool requires a real OS or VM."
fi
# systemd-detect-virt: only reject real container runtimes, allow all VM hypervisors
if command -v systemd-detect-virt &>/dev/null; then
    VIRT_TYPE=$(systemd-detect-virt 2>/dev/null || echo "none")
    # These are containers/LXC-like — reject them
    case "$VIRT_TYPE" in
        lxc|lxc-libvirt|openvz|docker|podman|container|wsl|systemd-nspawn)
            die "Running in container (${VIRT_TYPE}). This tool requires a real OS or VM."
            ;;
    esac
fi
log_success "Not in container environment"

# 1d. Reject rescue/live boot
CMDLINE=$(cat /proc/cmdline 2>/dev/null || echo "")
if echo "$CMDLINE" | grep -qE '(rescue|live|liveimg|live-boot|inst\.stage2)'; then
    die "Running in rescue/live boot mode. Boot into normal OS first."
fi
log_success "Normal boot confirmed"

# 1e. OS compatibility check (Debian/Ubuntu only)
if [[ ! -f /etc/os-release ]]; then
    die "Cannot determine OS. /etc/os-release not found."
fi
source /etc/os-release
OS_ID="${ID:-}"
OS_LIKE="${ID_LIKE:-}"

if [[ "$OS_ID" != "debian" && "$OS_ID" != "ubuntu" ]] && \
   [[ "$OS_LIKE" != *"debian"* && "$OS_LIKE" != *"ubuntu"* ]]; then
    log_warn "This tool is designed for Debian/Ubuntu. Your OS: $PRETTY_NAME"
    log_warn "Proceeding anyway, but GRUB config may differ."
fi
log_info "OS detected: ${PRETTY_NAME:-$OS_ID}"

# ---------------------------------------------------------------------------
# PHASE 2: Dependency check & install
# ---------------------------------------------------------------------------
banner "Phase 2: Dependency check"

REQUIRED_TOOLS=("wget" "curl" "ip" "lsblk" "blkid" "fdisk" "grub-install" "grub-reboot" "sha256sum" "gunzip" "tar")
MISSING_TOOLS=()

for tool in "${REQUIRED_TOOLS[@]}"; do
    if ! command -v "$tool" &>/dev/null; then
        MISSING_TOOLS+=("$tool")
    fi
done

if [[ ${#MISSING_TOOLS[@]} -gt 0 ]]; then
    log_warn "Missing tools: ${MISSING_TOOLS[*]}"
    log_info "Attempting to install..."
    if command -v apt &>/dev/null; then
        apt-get update -qq || true
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq wget curl iproute2 util-linux fdisk grub2-common sha256sum gzip xz-utils tar || true
    elif command -v dnf &>/dev/null; then
        dnf install -y wget curl iproute2 util-linux fdisk grub2-common sha256sum gzip xz-utils tar || true
    fi
fi

# Re-check after install attempt
STILL_MISSING=()
for tool in "${REQUIRED_TOOLS[@]}"; do
    if ! command -v "$tool" &>/dev/null; then
        STILL_MISSING+=("$tool")
    fi
done

if [[ ${#STILL_MISSING[@]} -gt 0 ]]; then
    die "Required tools still missing: ${STILL_MISSING[*]}. Please install them manually."
fi
log_success "All required tools available"

# Special: check for zstd (optional but recommended)
if command -v zstd &>/dev/null; then
    log_info "zstd found (will handle .zst compressed images)"
else
    log_warn "zstd not found. If your image is .zst compressed, install with: apt install zstd"
fi

# ---------------------------------------------------------------------------
# PHASE 3: Hardware detection (informational only)
# ---------------------------------------------------------------------------
banner "Phase 3: Hardware detection"

# 3a. Hypervisor detection
SYS_VENDOR="unknown"
SYS_PRODUCT="unknown"

if [[ -f /sys/class/dmi/id/sys_vendor ]]; then
    SYS_VENDOR=$(tr -d '\0' < /sys/class/dmi/id/sys_vendor || echo "unknown")
fi
if [[ -f /sys/class/dmi/id/product_name ]]; then
    SYS_PRODUCT=$(tr -d '\0' < /sys/class/dmi/id/product_name || echo "unknown")
fi

# Detect hypervisor via systemd if available
if command -v systemd-detect-virt &>/dev/null; then
    HYPERVISOR=$(systemd-detect-virt 2>/dev/null || echo "none")
else
    HYPERVISOR="unknown"
fi

log_info "Vendor:     $SYS_VENDOR"
log_info "Product:    $SYS_PRODUCT"
log_info "Hypervisor: $HYPERVISOR"

# 3b. Firmware detection (UEFI vs BIOS)
if $FORCE_BIOS; then
    FIRMWARE="bios"
    log_warn "FORCE BIOS MODE: Overriding UEFI detection — using legacy BIOS boot"
    log_warn "This requires CSM (Compatibility Support Module) in firmware."
else
    if [[ -d /sys/firmware/efi ]]; then
        FIRMWARE="uefi"
        log_info "Firmware: UEFI"
    else
        FIRMWARE="bios"
        log_info "Firmware: Legacy BIOS"
    fi
fi

# 3c. Memory info
MEM_TOTAL_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
MEM_TOTAL_MB=$((MEM_TOTAL_KB / 1024))
log_info "Memory: ${MEM_TOTAL_MB} MB"

# 3d. Network interfaces
IFACE=$(ip route show default 2>/dev/null | awk '/default/ {for(i=1;i<=NF;i++) if($i=="dev") print $(i+1); exit}')
if [[ -z "$IFACE" ]]; then
    IFACE=$(ip link show | awk -F: '$0 !~ "lo|vir|docker|^[^0-9]"{print $2; exit}' | xargs)
fi
log_info "Primary NIC: ${IFACE:-unknown}"

# Get IP addresses (POSIX-safe, no grep -P)
if [[ -n "$IFACE" ]]; then
    IPV4=$(ip -4 addr show "$IFACE" 2>/dev/null | awk '/inet /{print $2}' | cut -d/ -f1 | head -1)
    IPV6=$(ip -6 addr show "$IFACE" 2>/dev/null | awk '/inet6 /{print $2}' | cut -d/ -f1 | head -1)
    log_info "IPv4: ${IPV4:-none}"
    log_info "IPv6: ${IPV6:-none}"
fi

# ---------------------------------------------------------------------------
# PHASE 4: Disk scanning & selection
# ---------------------------------------------------------------------------
banner "Phase 4: Disk scanning"

scan_disks() {
    lsblk -nd -o NAME,SIZE,TYPE,MODEL,RO 2>/dev/null | while read -r name size type model ro; do
        # Skip non-disk types
        if [[ "$type" != "disk" ]]; then
            continue
        fi
        # Skip loop, ram, sr (CDROM), zd (zvol) devices
        if [[ "$name" =~ ^(loop|ram|sr|zd) ]]; then
            continue
        fi
        local dev="/dev/$name"
        # Skip read-only devices (CDROM, etc.)
        if [[ "$ro" == "1" ]]; then
            continue
        fi
        # Skip RAID members
        if blkid "$dev" 2>/dev/null | grep -q "linux_raid_member"; then
            continue
        fi
        # Get size in bytes for sorting
        local size_bytes
        size_bytes=$(blockdev --getsize64 "$dev" 2>/dev/null) || size_bytes=0
        if (( size_bytes == 0 )); then
            local sectors
            sectors=$(cat "/sys/block/$name/size" 2>/dev/null || echo 0)
            size_bytes=$((sectors * 512))
        fi
        echo "$dev|$size|$model|$size_bytes"
    done
}

# Auto-select the largest writable disk
auto_select_largest_disk() {
    local largest_dev="" largest_bytes=0

    while IFS='|' read -r dev size model size_bytes; do
        if (( size_bytes > largest_bytes )); then
            largest_bytes=$size_bytes
            largest_dev="$dev"
        fi
    done < <(scan_disks)

    if [[ -z "$largest_dev" ]]; then
        die "No writable disk found."
    fi

    echo "$largest_dev"
}

DISKS=$(scan_disks)

if [[ -z "$DISKS" ]]; then
    die "No usable disks found. Check your system."
fi

declare -a DISK_ARRAY
echo ""
echo "  #   DEVICE          SIZE        MODEL"
echo "  --- -------------- ----------- ----------------------------------"
i=1
while IFS='|' read -r dev size model size_bytes; do
    DISK_ARRAY+=("$dev")
    printf "  %-3d %-14s %-11s %s\n" "$i" "$dev" "$size" "${model:-unknown}"
    i=$((i+1))
done <<< "$DISKS"
echo ""

# 4a. Disk selection: auto (largest) or manual via --disk
if [[ -n "$TARGET_DISK" ]]; then
    # Validate provided disk
    if [[ ! -b "$TARGET_DISK" ]]; then
        die "Specified disk '$TARGET_DISK' is not a valid block device."
    fi
    FOUND=false
    for d in "${DISK_ARRAY[@]}"; do
        [[ "$d" == "$TARGET_DISK" ]] && FOUND=true && break
    done
    if ! $FOUND; then
        log_warn "Disk '$TARGET_DISK' was not found in scan. Proceeding anyway."
    fi
    log_info "Using specified disk: $TARGET_DISK"
else
    # Auto-select: largest writable disk
    TARGET_DISK=$(auto_select_largest_disk)
    log_info "Auto-selected largest disk: $TARGET_DISK"
    log_info "(Use --disk /dev/XXX to choose a different disk)"
fi

# 4b. RAID check
if blkid "$TARGET_DISK" 2>/dev/null | grep -qi "linux_raid_member"; then
    die "Disk '$TARGET_DISK' is part of a RAID array. RAID is not supported."
fi
log_success "Target disk: $TARGET_DISK"

# 4c. Disk size check
DISK_SIZE_BYTES=$(blockdev --getsize64 "$TARGET_DISK" 2>/dev/null || echo 0)
if [[ "$DISK_SIZE_BYTES" == "0" ]]; then
    DISK_SIZE_SECTORS=$(cat "/sys/block/$(basename "$TARGET_DISK")/size" 2>/dev/null || echo 0)
    DISK_SIZE_BYTES=$((DISK_SIZE_SECTORS * 512))
fi
DISK_SIZE_GB=$((DISK_SIZE_BYTES / 1024 / 1024 / 1024))
log_info "Disk size: ${DISK_SIZE_GB} GB"

# ---------------------------------------------------------------------------
# PHASE 5: Determine OS image type from URL
# ---------------------------------------------------------------------------
banner "Phase 5: Image URL analysis"

IMAGE_FILENAME=$(basename "$IMAGE_URL" | sed 's/[?#].*//')
IMAGE_EXT=""
COMPRESSION=""

case "$IMAGE_FILENAME" in
    *.raw.zst)  IMAGE_EXT="raw";  COMPRESSION="zst" ;;
    *.raw.gz)   IMAGE_EXT="raw";  COMPRESSION="gz"  ;;
    *.raw.xz)   IMAGE_EXT="raw";  COMPRESSION="xz"  ;;
    *.raw.bz2)  IMAGE_EXT="raw";  COMPRESSION="bz2" ;;
    *.raw)      IMAGE_EXT="raw";  COMPRESSION=""     ;;
    *.img.zst)  IMAGE_EXT="img";  COMPRESSION="zst" ;;
    *.img.gz)   IMAGE_EXT="img";  COMPRESSION="gz"  ;;
    *.img.xz)   IMAGE_EXT="img";  COMPRESSION="xz"  ;;
    *.img)      IMAGE_EXT="img";  COMPRESSION=""     ;;
    *.qcow2)    IMAGE_EXT="qcow2"; COMPRESSION=""    ;;
    *.vhd|*.vhdx) IMAGE_EXT="vhd"; COMPRESSION=""   ;;
    *.vmdk)     IMAGE_EXT="vmdk";  COMPRESSION=""    ;;
    *.iso)      IMAGE_EXT="iso";   COMPRESSION=""    ;;
    *)
        die "Unknown image format: $IMAGE_FILENAME. Supported: .raw.zst, .raw.gz, .img.gz, .raw, .img, .qcow2, .vhd, .vmdk"
        ;;
esac

log_info "Image filename: $IMAGE_FILENAME"
log_info "Image format:   $IMAGE_EXT"
log_info "Compression:    ${COMPRESSION:-none}"

# Check if needed decompressor is available
case "$COMPRESSION" in
    zst)
        if ! command -v zstd &>/dev/null; then
            log_info "Installing zstd..."
            apt-get install -y -qq zstd || die "Failed to install zstd"
        fi
        ;;
    xz)
        if ! command -v xz &>/dev/null; then
            apt-get install -y -qq xz-utils || die "Failed to install xz-utils"
        fi
        ;;
    bz2)
        if ! command -v bzip2 &>/dev/null; then
            apt-get install -y -qq bzip2 || die "Failed to install bzip2"
        fi
        ;;
esac

# ---------------------------------------------------------------------------
# PHASE 6: Download OS image
# ---------------------------------------------------------------------------
banner "Phase 6: Download OS image"

log_info "Downloading from: $IMAGE_URL"
log_info "Destination: $STAGE2_IMAGE"

# Check free space where the image will actually be stored (STAGE2_DIR,
# on the root filesystem — not /boot, which is often a tiny partition)
DATA_FREE=$(df -m "$STAGE2_DIR" 2>/dev/null | awk 'NR==2 {print $4}')
DATA_FREE_GB=$((DATA_FREE / 1024))
log_info "Free space in ${STAGE2_DIR}: ${DATA_FREE} MB (${DATA_FREE_GB} GB)"

# Try to find out the remote file size up front so we can fail fast instead
# of downloading for a while and then hitting ENOSPC mid-transfer.
REMOTE_SIZE_BYTES=$(curl -sIL "$IMAGE_URL" 2>/dev/null | tr -d '\r' | awk -F': ' 'tolower($1)=="content-length" {print $2}' | tail -1)
if [[ -n "${REMOTE_SIZE_BYTES:-}" && "$REMOTE_SIZE_BYTES" =~ ^[0-9]+$ ]]; then
    REMOTE_SIZE_MB=$((REMOTE_SIZE_BYTES / 1024 / 1024))
    # Require remote size + 10% safety margin
    REQUIRED_MB=$((REMOTE_SIZE_MB + REMOTE_SIZE_MB / 10))
    log_info "Remote image size: ${REMOTE_SIZE_MB} MB (need ~${REQUIRED_MB} MB free with margin)"
    if (( DATA_FREE < REQUIRED_MB )); then
        die "Not enough space in ${STAGE2_DIR}: have ${DATA_FREE} MB, need ~${REQUIRED_MB} MB. Free up space or point STAGE2_DIR at a larger filesystem."
    fi
else
    log_warn "Could not determine remote image size ahead of time (server may not report Content-Length). Proceeding, but download may fail mid-transfer if space runs low."
fi

# Download with aria2c (multi-connection, max speed) or fallback to wget/curl
download_image() {
    local url="$1"
    local dest="$2"
    local retries=3

    # Install aria2 if not present (fastest downloader)
    if ! command -v aria2c &>/dev/null; then
        log_info "Installing aria2 for high-speed download..."
        apt-get update -qq 2>/dev/null || true
        apt-get install -y -qq aria2 2>/dev/null || log_info "aria2 not available, using wget/curl"
    fi

    for attempt in $(seq 1 $retries); do
        log_info "Download attempt $attempt/$retries..."

        # Method 1: aria2c — multi-connection, max speed
        if command -v aria2c &>/dev/null; then
            log_info "Using aria2c (max connections, resume support)..."
            # aria2c with: 16 connections, continue/resume, show progress
            if aria2c -x 16 -s 16 -c --max-connection-per-server=16 \
                --min-split-size=1M --console-log-level=notice \
                --summary-interval=5 \
                -d "$(dirname "$dest")" -o "$(basename "$dest")" "$url" 2>&1 | tee -a "$LOGFILE"; then
                log_success "Download completed (aria2c)"
                return 0
            fi
            log_warn "aria2c failed, trying wget..."
        fi

        # Method 2: wget with resume
        if wget --no-check-certificate -4 -c --progress=bar:force:noscroll \
            -O "$dest" "$url" 2>&1 | tee -a "$LOGFILE"; then
            log_success "Download completed (wget)"
            return 0
        fi

        # Method 3: curl with resume
        if curl -L -C - --progress-bar -o "$dest" "$url" 2>&1 | tee -a "$LOGFILE"; then
            log_success "Download completed (curl)"
            return 0
        fi

        if (( attempt < retries )); then
            log_warn "Download failed, retrying in 5 seconds..."
            sleep 5
        else
            rm -f "$dest"
        fi
    done

    return 1
}

# Compute SHA256 (busybox compatible)
compute_sha256() {
    local file="$1"
    if command -v sha256sum &>/dev/null; then
        sha256sum "$file" | awk '{print $1}'
    elif command -v openssl &>/dev/null; then
        openssl dgst -sha256 "$file" | awk '{print $NF}'
    else
        echo ""
    fi
}

# === SMART IMAGE RE-USE LOGIC ===
NEED_DOWNLOAD=true

if [[ -f "$STAGE2_IMAGE" ]]; then
    EXISTING_SIZE=$(stat -c%s "$STAGE2_IMAGE" 2>/dev/null || echo 0)
    log_info "Existing image found: $STAGE2_IMAGE ($((EXISTING_SIZE/1024/1024)) MB)"

    # If we have a stored checksum, verify the existing file
    if [[ -f "$STAGE2_IMAGE_CHECKSUM" ]]; then
        STORED_CHECKSUM=$(awk '{print $1}' "$STAGE2_IMAGE_CHECKSUM")
        COMPUTED_CHECKSUM=$(compute_sha256 "$STAGE2_IMAGE")

        if [[ -n "$STORED_CHECKSUM" && -n "$COMPUTED_CHECKSUM" ]] && \
           [[ "$STORED_CHECKSUM" == "$COMPUTED_CHECKSUM" ]]; then
            log_success "Existing image checksum VERIFIED — reusing"
            NEED_DOWNLOAD=false
        else
            log_warn "Checksum mismatch! Stored: ${STORED_CHECKSUM:0:16}..."
            log_warn "                 Computed: ${COMPUTED_CHECKSUM:0:16}..."
            log_warn "Existing image is CORRUPTED or INCOMPLETE — will re-download"
            rm -f "$STAGE2_IMAGE" "$STAGE2_IMAGE_CHECKSUM"
        fi
    else
        # No checksum stored — assume incomplete, force re-download
        if (( EXISTING_SIZE < 100 * 1024 * 1024 )); then
            log_warn "Existing image too small ($((EXISTING_SIZE/1024/1024)) MB < 100 MB) — re-downloading"
            rm -f "$STAGE2_IMAGE" "$STAGE2_IMAGE_CHECKSUM"
        else
            log_info "No stored checksum, but image is large enough. Computing checksum now..."
            COMPUTED_CHECKSUM=$(compute_sha256 "$STAGE2_IMAGE")
            echo "$COMPUTED_CHECKSUM  $STAGE2_IMAGE" > "$STAGE2_IMAGE_CHECKSUM"
            stat -c%s "$STAGE2_IMAGE" > "$STAGE2_IMAGE_SIZE"
            log_info "Checksum saved for future verification"
            NEED_DOWNLOAD=false
        fi
    fi
fi

if $NEED_DOWNLOAD; then
    if $DRY_RUN; then
        log_info "[DRY RUN] Would download $IMAGE_URL to $STAGE2_IMAGE"
    else
        rm -f "$STAGE2_IMAGE" "$STAGE2_IMAGE_CHECKSUM" "$STAGE2_IMAGE_SIZE"
        if ! download_image "$IMAGE_URL" "$STAGE2_IMAGE"; then
            die "Failed to download image after all retries."
        fi

        # Verify downloaded file is not empty
        DOWNLOADED_SIZE=$(stat -c%s "$STAGE2_IMAGE" 2>/dev/null || echo 0)
        if (( DOWNLOADED_SIZE < 10 * 1024 * 1024 )); then
            die "Downloaded image is too small ($((DOWNLOADED_SIZE/1024/1024)) MB). Download likely failed."
        fi

        # Store size for Stage 2
        echo "$DOWNLOADED_SIZE" > "$STAGE2_IMAGE_SIZE"

        # Compute SHA256 checksum
        log_info "Computing SHA256 checksum..."
        CHK=$(compute_sha256 "$STAGE2_IMAGE")
        echo "$CHK  $STAGE2_IMAGE" > "$STAGE2_IMAGE_CHECKSUM"
        log_info "SHA256: $CHK"
    fi
fi

IMAGE_SIZE_MB=$(stat -c%s "$STAGE2_IMAGE" 2>/dev/null | awk '{printf "%.0f", $1/1024/1024}')
log_info "Image size: ${IMAGE_SIZE_MB} MB"

# Warn if image is smaller than target disk
DISK_SIZE_MB=$((DISK_SIZE_BYTES / 1024 / 1024))
if (( IMAGE_SIZE_MB > DISK_SIZE_MB )); then
    die "Image size (${IMAGE_SIZE_MB} MB) is larger than target disk (${DISK_SIZE_MB} MB)!"
fi
log_success "Image fits on target disk (${IMAGE_SIZE_MB} MB < ${DISK_SIZE_MB} MB)"

# ---------------------------------------------------------------------------
# PHASE 6b: Firmware/image compatibility check
# ---------------------------------------------------------------------------
banner "Phase 6b: Firmware compatibility check"

log_info "Host firmware: ${FIRMWARE^^}"
log_info "Image will be written with partition table matching host firmware"

if [[ "$FIRMWARE" == "uefi" ]]; then
    log_info "UEFI mode: GRUB will use EFI modules, target must support UEFI boot"
    log_warn "If your OS image was built for BIOS/MBR only, it WILL NOT BOOT on this UEFI system."
    log_info "Fix: Use a UEFI-compatible OS image, or switch host to BIOS boot."
elif [[ "$FIRMWARE" == "bios" ]]; then
    log_info "BIOS mode: GRUB will use legacy MBR boot"
    log_warn "If your OS image was built for UEFI/GPT only, it WILL NOT BOOT on this BIOS system."
    log_info "Fix: Use a BIOS-compatible OS image, or switch host to UEFI boot."
fi

echo ""
log_info "TIP: Most cloud images (Ubuntu, Debian) support both UEFI and BIOS."
log_info "     Windows images built for UEFI need GPT; for BIOS need MBR."

# ---------------------------------------------------------------------------
# ---------------------------------------------------------------------------
# PHASE 6c: Quick image check
# ---------------------------------------------------------------------------
banner "Phase 6c: Image check"

# Partition table type (fast, no mount needed)
IMAGE_PT=$(fdisk -l "$STAGE2_IMAGE" 2>/dev/null | grep -i "disklabel type" | awk -F': ' '{print $2}' | tr '[:upper:]' '[:lower:]')
[[ -z "$IMAGE_PT" ]] && IMAGE_PT=$(blkid "$STAGE2_IMAGE" 2>/dev/null | grep -oi 'PTTYPE="[^"]*"' | cut -d'"' -f2 | tr '[:upper:]' '[:lower:]')
log_info "Partition table: ${IMAGE_PT:-unknown}"

# Guess OS from URL
case "$(echo "$IMAGE_URL" | tr '[:upper:]' '[:lower:]')" in
    *win*|*windows*|*2022*|*2019*|*2016*|*ltsc*|*10*|*11*)
        log_info "OS guess: Windows (from URL)"; IMAGE_OSTYPE="Windows" ;;
    *debian*|*ubuntu*|*alma*|*rocky*|*fedora*|*arch*|*alpine*|*linux*)
        log_info "OS guess: Linux (from URL)"; IMAGE_OSTYPE="Linux" ;;
    *) log_info "OS: unknown"; IMAGE_OSTYPE="unknown" ;;
esac

# Fix firmware mismatch (image=MBR + host=UEFI => force BIOS)
if [[ "$IMAGE_PT" == "dos" && "$FIRMWARE" == "uefi" ]]; then
    log_warn "Image is MBR, host is UEFI — auto-enabling BIOS mode (CSM required)"
    FIRMWARE="bios"
elif [[ "$IMAGE_PT" == "gpt" && "$FIRMWARE" == "bios" ]]; then
    log_info "Image is GPT, host is BIOS — should work via protective MBR"
else
    log_success "Partition table and firmware are compatible"
fi

# ---------------------------------------------------------------------------
# PHASE 7: Prepare Stage 2 kernel & initramfs
# ---------------------------------------------------------------------------
# PHASE 7: Prepare Stage 2 kernel & initramfs
# ---------------------------------------------------------------------------
banner "Phase 7: Prepare Stage 2 (kernel + initramfs)"

# Strategy: use GRUB loopback boot like TinyInstaller.
# If image is raw/uncompressed: GRUB mounts image as loop, boots kernel FROM INSIDE.
# If image is compressed or Windows: fallback to host kernel + custom initramfs.

# ---------------------------------------------------------------------------
# 7a: Try GRUB LOOPBACK approach (Linux images, raw format)
# ---------------------------------------------------------------------------
USE_LOOPBACK=false
LOOPBACK_KERNEL=""
LOOPBACK_INITRD=""

try_loopback_approach() {
    # Only works for raw/uncompressed images
    case "$IMAGE_FILENAME" in
        *.raw|*.img)
            :
            ;;
        *)
            log_info "Compressed image — cannot use loopback, falling back to host kernel"
            return 1
            ;;
    esac

    log_info "Attempting GRUB loopback boot (like TinyInstaller)..."

    # Mount image as loop to discover kernel/initrd paths
    local loopdev
    loopdev=$(losetup --find --show --partscan "$STAGE2_IMAGE" 2>/dev/null)
    if [[ -z "$loopdev" ]]; then
        log_info "losetup failed — cannot use loopback"
        return 1
    fi

    sleep 1

    # Try to mount root partition
    local mounted=false
    local mountpoint
    mountpoint=$(mktemp -d /tmp/osreinstall-loop.XXXXXX)

    for part in "${loopdev}p1" "${loopdev}p2" "${loopdev}1" "${loopdev}2" "${loopdev}p3" "${loopdev}3"; do
        if [[ -b "$part" ]]; then
            for fstype in ext4 xfs btrfs ext3 ext2; do
                if mount -t "$fstype" -o ro "$part" "$mountpoint" 2>/dev/null; then
                    mounted=true
                    log_info "Mounted image root: $part ($fstype)"
                    break 2
                fi
            done
        fi
    done

    if ! $mounted; then
        log_info "Could not mount image — cannot use loopback (possibly Windows image or LVM)"
        losetup -d "$loopdev" 2>/dev/null || true
        rmdir "$mountpoint" 2>/dev/null || true
        return 1
    fi

    # Find kernel and initrd inside the image
    local vmlinuz_found=""
    local initrd_found=""
    vmlinuz_found=$(find "$mountpoint/boot" -maxdepth 1 -name 'vmlinuz-*' 2>/dev/null | head -1)
    [[ -z "$vmlinuz_found" ]] && vmlinuz_found=$(find "$mountpoint/boot" -maxdepth 1 -name 'vmlinuz' 2>/dev/null | head -1)
    initrd_found=$(find "$mountpoint/boot" -maxdepth 1 -name 'initrd.img-*' 2>/dev/null | head -1)
    [[ -z "$initrd_found" ]] && initrd_found=$(find "$mountpoint/boot" -maxdepth 1 -name 'initrd*' 2>/dev/null | head -1)

    if [[ -n "$vmlinuz_found" && -n "$initrd_found" ]]; then
        # Strip mountpoint prefix to get relative path inside image
        LOOPBACK_KERNEL="${vmlinuz_found#$mountpoint}"
        LOOPBACK_INITRD="${initrd_found#$mountpoint}"
        log_success "Found kernel: $LOOPBACK_KERNEL"
        log_success "Found initrd: $LOOPBACK_INITRD"
        USE_LOOPBACK=true
    else
        log_info "No Linux kernel found in image — Windows image detected, using host kernel"
    fi

    umount "$mountpoint" 2>/dev/null || true
    losetup -d "$loopdev" 2>/dev/null || true
    rmdir "$mountpoint" 2>/dev/null || true

    $USE_LOOPBACK
}

# Try loopback if image is raw
# NOTE: loopback boot is DISABLED. It boots the guest's own kernel directly
# from inside the downloaded image without ever passing it a `root=` kernel
# parameter, and — more importantly — it never actually writes the image to
# $TARGET_DISK (that only happens in host-kernel mode below). Using it here
# would just live-boot the downloaded OS from the loop file (causing a
# "No working init found" panic on top of that) instead of performing the
# reinstall. Always use host-kernel-mode, which does the real dd-based write.
if false && try_loopback_approach; then
    log_success "Using GRUB loopback boot (TinyInstaller method)"
    log_info "Kernel: $LOOPBACK_KERNEL"
    log_info "Initrd: $LOOPBACK_INITRD"
    # No need to build custom initramfs — we reuse the image's own
    # We just reference the image file in the GRUB entry
else
    # Fallback: use host kernel + custom initramfs

    log_info "Checking host kernel for virtio support..."

    find_host_kernel() {
        local kernel_ver
        kernel_ver=$(uname -r)
        echo "$kernel_ver"
    }

    KERNEL_VER=$(find_host_kernel)
    KERNEL_IMAGE=""

    # Find the current kernel image
    if [[ -f "/boot/vmlinuz-$KERNEL_VER" ]]; then
        KERNEL_IMAGE="/boot/vmlinuz-$KERNEL_VER"
    elif [[ -f "/vmlinuz" ]]; then
        KERNEL_IMAGE="/vmlinuz"
    elif ls /boot/vmlinuz-* &>/dev/null; then
        KERNEL_IMAGE=$(ls -t /boot/vmlinuz-* 2>/dev/null | head -1)
    else
        die "Could not find kernel image in /boot/"
    fi

    log_info "Host kernel: $KERNEL_VER"

    # Check if host kernel has virtio modules
    has_virtio=false
    if [[ -d "/lib/modules/$KERNEL_VER/kernel/drivers/virtio" ]]; then
        has_virtio=true
        log_success "Host kernel has virtio drivers"
    elif [[ -d "/lib/modules/$KERNEL_VER/kernel/drivers/block/virtio_blk.ko"* ]] 2>/dev/null; then
        has_virtio=true
    elif find "/lib/modules/$KERNEL_VER" -name "virtio_net.ko*" 2>/dev/null | grep -q virtio; then
        has_virtio=true
        log_success "Virtio modules found in host kernel"
    fi

    if ! $has_virtio; then
        log_warn "Host kernel lacks virtio drivers — auto-downloading generic kernel..."
        auto_kernel_base="https://deb.debian.org/debian/pool/main/l/linux-signed-amd64"
        auto_kernel_version=""

        # Try to find the latest available kernel
        # Download the Packages index to find latest version (small file)
        pkg_index="/tmp/debian-kernel-packages.gz"
        wget -qO "$pkg_index" "https://deb.debian.org/debian/dists/stable/main/binary-amd64/Packages.gz" 2>/dev/null || true

        if [[ -f "$pkg_index" ]]; then
            auto_kernel_version=$(zcat "$pkg_index" 2>/dev/null | awk '
                /^Package: linux-image-6\./{pkg=$2}
                /^Version:/ && pkg {ver=$2; gsub(/^.*linux-image-/,"",pkg); 
                if (!seen[ver]) {print ver; seen[ver]=1}}' | sort -V | tail -1)
            rm -f "$pkg_index"
        fi

        if [[ -z "$auto_kernel_version" ]]; then
            # Fallback to known good kernel
            auto_kernel_version="6.1.0-28-amd64"
        fi

        auto_kernel_url="${auto_kernel_base}/linux-image-${auto_kernel_version}_${auto_kernel_version#*-}_amd64.deb"

        log_info "Auto kernel: $auto_kernel_version"
        log_info "Downloading from Debian repo..."

        deb_file="/tmp/osreinstall-kernel.deb"
        rm -f "$deb_file"
        if wget --no-check-certificate -4 -q --show-progress \
            -O "$deb_file" "$auto_kernel_url" 2>&1 | tee -a "$LOGFILE"; then
            log_success "Kernel package downloaded"
            # Extract vmlinuz from the .deb
            extract_dir="/tmp/osreinstall-kernel-extract"
            rm -rf "$extract_dir"
            mkdir -p "$extract_dir"
            dpkg-deb -x "$deb_file" "$extract_dir" 2>/dev/null || {
                # Manual extraction if dpkg-deb not available
                ar x "$deb_file" --output="$extract_dir" data.tar.xz 2>/dev/null || true
                tar -xf "$extract_dir/data.tar.xz" -C "$extract_dir" 2>/dev/null || true
            }
            kernel_found
            kernel_found=$(find "$extract_dir/boot" -name 'vmlinuz-*' 2>/dev/null | head -1)
            if [[ -n "$kernel_found" ]]; then
                cp "$kernel_found" "$STAGE2_KERNEL"
                log_success "Generic kernel installed: $STAGE2_KERNEL"
                # Also copy modules so our initramfs can use them
                mkdir -p "/lib/modules/"
                cp -r "$extract_dir/lib/modules/"* "/lib/modules/" 2>/dev/null || true
            fi
            rm -rf "$extract_dir" "$deb_file"
        else
            log_warn "Failed to download generic kernel — using host kernel anyway"
            if ! $DRY_RUN; then
                cp "$KERNEL_IMAGE" "$STAGE2_KERNEL"
            fi
        fi
    else
        # Host kernel has virtio — use it directly
        log_info "Copying host kernel: $KERNEL_IMAGE"
        if ! $DRY_RUN; then
            cp "$KERNEL_IMAGE" "$STAGE2_KERNEL"
        fi
    fi

    log_info "Kernel ready at $STAGE2_KERNEL"
fi

# Now build the Stage 2 initramfs
# We drop a custom init script into the initramfs that handles:
#   - Disk detection
#   - Image write
#   - Partition resize
#   - GRUB installation to target

# The init script is embedded below (stage2_init)
# We'll create a minimal initramfs with busybox + our script

build_stage2_initramfs() {
    local tmpdir
    tmpdir=$(mktemp -d /tmp/osreinstall-initramfs.XXXXXX)

    log_info "Building Stage 2 initramfs in $tmpdir..."

    # Create minimal initramfs structure
    mkdir -p "$tmpdir"/{bin,dev,etc,lib,lib64,mnt,proc,root,run,sbin,sys,tmp,usr/{bin,sbin,lib,lib64,share}}

    # Copy busybox (static if possible)
    if command -v busybox &>/dev/null; then
        cp "$(command -v busybox)" "$tmpdir/bin/busybox"
    elif [[ -f /usr/lib/initramfs-tools/bin/busybox ]]; then
        cp /usr/lib/initramfs-tools/bin/busybox "$tmpdir/bin/busybox"
    elif [[ -f /bin/busybox ]]; then
        cp /bin/busybox "$tmpdir/bin/busybox"
    else
        log_warn "busybox not found, installing..."
        apt-get install -y -qq busybox-static busybox || true
        if command -v busybox &>/dev/null; then
            cp "$(command -v busybox)" "$tmpdir/bin/busybox"
        else
            die "Cannot find busybox. Required for Stage 2 initramfs."
        fi
    fi

    chmod +x "$tmpdir/bin/busybox"

    # Create busybox symlinks
    local busybox_applets=(
        "sh" "ash" "cat" "cp" "dd" "echo" "ls" "mkdir" "mktemp" "mount" "umount" "sleep"
        "grep" "awk" "sed" "cut" "head" "tail" "tr" "wc" "printf" "test" "[" "[["
        "chmod" "chown" "ln" "rm" "rmdir" "sync" "blockdev" "mdev"
        "reboot" "poweroff" "switch_root" "kill" "pidof"
        "df" "du" "stat" "basename" "dirname" "readlink"
        "expr" "seq" "fold" "getopt" "which"
    )
    for applet in "${busybox_applets[@]}"; do
        ln -sf busybox "$tmpdir/bin/$applet" 2>/dev/null || true
    done
    ln -sf busybox "$tmpdir/sbin/mdev" 2>/dev/null || true

    # Install Stage 2 init script (embedded below)
    # IMPORTANT: write the init file FIRST, then set permissions.
    # Do NOT symlink to busybox first — causes "Text file busy" on overlay/tmpfs.
    cat > "$tmpdir/init" << 'STAGE2INIT'
#!/bin/busybox sh
# ==========================================================================
# OS Reinstaller Stage 2 — Initramfs Init Script
# ==========================================================================
# This runs after reboot, inside a generic initramfs.
# It detects the target disk, writes the OS image, and sets up the new OS.
# ==========================================================================

export PATH=/bin:/sbin:/usr/bin:/usr/sbin

# -----------------------------------------------------------------
# Initialize devices and filesystems
# -----------------------------------------------------------------
mount -t proc  proc  /proc
mount -t sysfs sysfs /sys
mount -t devtmpfs devtmpfs /dev
mount -t tmpfs  tmpfs /tmp
mount -t tmpfs  tmpfs /run

# Setup busybox mdev for device nodes
/sbin/mdev -s 2>/dev/null || true

# Log to ALL outputs: serial, console, and logfile
# (don't redirect everything to serial-only like before)
LOG="/run/install.log"
:> "$LOG"

log_msg() {
    local ts
    ts=$(cat /proc/uptime | cut -d. -f1 2>/dev/null || echo "0")
    local msg="[${ts}s] $*"
    echo "$msg" | tee -a "$LOG"
    echo "$msg" > /dev/console 2>/dev/null || true
    echo "$msg" > /dev/ttyS0 2>/dev/null || true
    echo "$msg" > /dev/tty0 2>/dev/null || true
    echo "$msg" > /dev/tty1 2>/dev/null || true
}

log_msg "=== OS Reinstaller Stage 2 Starting ==="
log_msg "Uptime: $(cat /proc/uptime)"

# -----------------------------------------------------------------
# Bring up network (for debugging via SSH/VNC if needed)
# -----------------------------------------------------------------
log_msg "=== BRINGING UP NETWORK ==="

# Load all network kernel modules
for mod in virtio_net virtio_pci vmxnet3 hv_netvsc xen_netfront e1000 e1000e r8169 igb ixgbe; do
    modprobe "$mod" 2>/dev/null && log_msg "Loaded module: $mod" || true
done

# Wait for NICs to appear
sleep 2

# Try DHCP on all interfaces
NIC_UP=false
for iface in $(ip link show 2>/dev/null | awk -F': ' '/^[0-9]+:/{print $2}' | grep -v lo); do
    ip link set up "$iface" 2>/dev/null || true
    log_msg "Interface $iface: link up"

    # Try DHCP
    if udhcpc -i "$iface" -n -q -t 3 2>/dev/null; then
        IP=$(ip addr show "$iface" 2>/dev/null | awk '/inet /{print $2}' | cut -d/ -f1)
        log_msg "DHCP OK on $iface: IP=$IP"
        NIC_UP=true
        break
    fi

    # Fallback: udhcpc not available, try dhclient
    if dhclient -1 "$iface" 2>/dev/null; then
        IP=$(ip addr show "$iface" 2>/dev/null | awk '/inet /{print $2}' | cut -d/ -f1)
        log_msg "DHCP OK on $iface: IP=$IP"
        NIC_UP=true
        break
    fi
done

if $NIC_UP; then
    log_msg "Network is UP — you can SSH in for debugging"
    log_msg "Dropbear/PAM not available; use VNC/serial console instead"
else
    log_msg "WARNING: Network NOT configured (no DHCP on any interface)"
    log_msg "Continuing without network — use VNC/serial console"
fi

# -----------------------------------------------------------------
# Parse kernel cmdline for parameters
# -----------------------------------------------------------------
CMDLINE=$(cat /proc/cmdline)
log_msg "Kernel cmdline: $CMDLINE"

extract_param() {
    local name="$1"
    local default="$2"
    local value=""
    for word in $CMDLINE; do
        case "$word" in
            "${name}="*)
                value="${word#${name}=}"
                break
                ;;
        esac
    done
    echo "${value:-$default}"
}

TARGET_DISK=$(extract_param "target_disk" "")
IMAGE_FILE=$(extract_param "image_file" "/osreinstall-data/osreinstall-disk.img")
IMAGE_CHECKSUM=$(extract_param "image_checksum" "")
IMAGE_FORMAT=$(extract_param "image_format" "raw")
DATA_FS_UUID=$(extract_param "data_fs_uuid" "")
STAGE2_DEBUG=$(extract_param "osreinstall_debug" "")

log_msg "Target disk: ${TARGET_DISK:-auto}"
log_msg "Image file:  $IMAGE_FILE"
log_msg "Image format: $IMAGE_FORMAT"
log_msg "Data fs UUID: ${DATA_FS_UUID:-unknown}"

# -----------------------------------------------------------------
# Mount the partition that holds the image (root fs by default, NOT
# necessarily /boot — see comment near STAGE2_DIR in stage 1).
# Preferred: mount by UUID passed on the kernel cmdline. Fall back to
# device-name guessing (/boot-style) only for older cmdlines/back-compat.
# -----------------------------------------------------------------
mkdir -p /mnt/data /boot 2>/dev/null || true
MOUNTED_DATA=false
DATA_MNT=""

if [[ -n "$DATA_FS_UUID" ]]; then
    dev_by_uuid=$(blkid -U "$DATA_FS_UUID" 2>/dev/null || findfs "UUID=$DATA_FS_UUID" 2>/dev/null)
    if [[ -n "$dev_by_uuid" ]] && mount "$dev_by_uuid" /mnt/data 2>/dev/null; then
        MOUNTED_DATA=true
        DATA_MNT=/mnt/data
        log_msg "Mounted $dev_by_uuid (UUID=$DATA_FS_UUID) to /mnt/data"
    fi
fi

if ! $MOUNTED_DATA; then
    log_msg "UUID mount unavailable/failed, falling back to device-name guessing (legacy /boot-style)..."
    if mount /boot 2>/dev/null; then
        MOUNTED_DATA=true; DATA_MNT=/boot
    elif mount /dev/sda1 /boot 2>/dev/null; then
        MOUNTED_DATA=true; DATA_MNT=/boot
    elif mount /dev/vda1 /boot 2>/dev/null; then
        MOUNTED_DATA=true; DATA_MNT=/boot
    elif mount /dev/nvme0n1p1 /boot 2>/dev/null; then
        MOUNTED_DATA=true; DATA_MNT=/boot
    elif mount /dev/xvda1 /boot 2>/dev/null; then
        MOUNTED_DATA=true; DATA_MNT=/boot
    else
        for dev in /dev/sd[a-z][0-9] /dev/vd[a-z][0-9] /dev/nvme[0-9]n[0-9]p[0-9] /dev/xvd[a-z][0-9]; do
            if mount -t ext4 "$dev" /boot 2>/dev/null || mount -t xfs "$dev" /boot 2>/dev/null; then
                MOUNTED_DATA=true; DATA_MNT=/boot
                break
            fi
        done
    fi
    [[ -n "$DATA_MNT" ]] && log_msg "Mounted (legacy fallback) to $DATA_MNT"
fi

if ! $MOUNTED_DATA; then
    log_msg "WARNING: Could not mount the data partition. Image must be accessible directly at $IMAGE_FILE"
fi

# -----------------------------------------------------------------
# Verify image file exists (try mountpoint-prefixed path first, then
# the raw path in case it's already visible at the initramfs root)
# -----------------------------------------------------------------
if [[ -n "$DATA_MNT" && -f "${DATA_MNT}${IMAGE_FILE}" ]]; then
    IMAGE_FILE="${DATA_MNT}${IMAGE_FILE}"
fi

if [[ ! -f "$IMAGE_FILE" ]]; then
    log_msg "ERROR: Image file not found at $IMAGE_FILE"
    log_msg "Contents of ${DATA_MNT:-/boot}:"
    ls -la "${DATA_MNT:-/boot}/" 2>/dev/null >> "$LOG"
    log_msg "Contents of /:"
    ls -la / >> "$LOG"

    # Fallback: try common paths on whichever mountpoint we got, plus legacy locations
    for candidate in \
        "${DATA_MNT}/osreinstall-data/osreinstall-disk.img" \
        "${DATA_MNT}/osreinstall-disk.img" \
        /boot/osreinstall-data/osreinstall-disk.img \
        /boot/osreinstall-disk.img \
        /osreinstall-data/osreinstall-disk.img \
        /osreinstall-disk.img; do
        if [[ -n "$candidate" && -f "$candidate" ]]; then
            log_msg "Found image at fallback: $candidate"
            IMAGE_FILE="$candidate"
            break
        fi
    done

    if [[ ! -f "$IMAGE_FILE" ]]; then
        log_msg "FATAL: No image found. Cannot continue."
        while true; do sleep 60; done
    fi
fi

IMAGE_SIZE=$(stat -c%s "$IMAGE_FILE" 2>/dev/null || echo 0)
log_msg "Image size: $IMAGE_SIZE bytes"

# -----------------------------------------------------------------
# Verify checksum if provided
# -----------------------------------------------------------------
if [[ -n "$IMAGE_CHECKSUM" ]]; then
    log_msg "Verifying image checksum..."
    COMPUTED=$(sha256sum "$IMAGE_FILE" 2>/dev/null | cut -d' ' -f1)
    if [[ "$COMPUTED" != "$IMAGE_CHECKSUM" ]]; then
        log_msg "CHECKSUM MISMATCH!"
        log_msg "  Expected: $IMAGE_CHECKSUM"
        log_msg "  Computed: $COMPUTED"
        log_msg "  Aborting install to prevent data corruption."
        while true; do sleep 60; done
    fi
    log_msg "Checksum verified OK"
fi

# -----------------------------------------------------------------
# Detect target disk
# -----------------------------------------------------------------
if [[ -z "$TARGET_DISK" ]]; then
    log_msg "Auto-detecting target disk..."
    # Strategy: find the disk that contains our current /boot
    CURRENT_DISK=""
    for dev in /dev/sd[a-z] /dev/vd[a-z] /dev/nvme[0-9]n[0-9] /dev/xvd[a-z]; do
        if lsblk -ndo NAME "$dev" 2>/dev/null | grep -q "$(basename "$dev")"; then
            CURRENT_DISK="$dev"
            break
        fi
    done

    if [[ -z "$CURRENT_DISK" ]]; then
        # Fallback: use first non-loop disk
        CURRENT_DISK=$(lsblk -ndo NAME -l 2>/dev/null | grep -vE '^(loop|sr|ram)' | head -1)
        CURRENT_DISK="/dev/${CURRENT_DISK}"
    fi

    TARGET_DISK="$CURRENT_DISK"
    log_msg "Auto-detected target disk: $TARGET_DISK"
fi

if [[ ! -b "$TARGET_DISK" ]]; then
    log_msg "ERROR: Target disk '$TARGET_DISK' is not a valid block device."
    log_msg "Available block devices:"
    lsblk -o NAME,SIZE,TYPE 2>/dev/null >> "$LOG" || ls -la /dev/sd* /dev/vd* /dev/nvme* 2>/dev/null >> "$LOG"
    while true; do sleep 60; done
fi

log_msg "=== WRITING IMAGE TO $TARGET_DISK ==="

# -----------------------------------------------------------------
# Write image to disk
# -----------------------------------------------------------------
write_image_raw() {
    local src="$1"
    local dst="$2"

    log_msg "Writing using dd (raw copy)..."
    dd if="$src" of="$dst" bs=4M conv=fsync status=progress 2>&1 | tee -a "$LOG"
    local rc=${PIPESTATUS[0]}
    if [[ $rc -ne 0 ]]; then
        log_msg "ERROR: dd failed with exit code $rc"
        return 1
    fi
    sync
    blockdev --flushbufs "$dst" 2>/dev/null || true
    log_msg "Write complete."
    return 0
}

write_image_gz() {
    local src="$1"
    local dst="$2"
    log_msg "Decompressing and writing with gzip + dd..."
    gunzip -c "$src" | dd of="$dst" bs=4M conv=fsync status=progress 2>&1 | tee -a "$LOG"
    local rc=${PIPESTATUS[0]}
    [[ $rc -ne 0 ]] && log_msg "ERROR: gunzip+dd failed" && return 1
    sync
    blockdev --flushbufs "$dst" 2>/dev/null || true
    return 0
}

write_image_zst() {
    local src="$1"
    local dst="$2"
    log_msg "Decompressing and writing with zstd + dd..."
    zstd -d -c "$src" | dd of="$dst" bs=4M conv=fsync status=progress 2>&1 | tee -a "$LOG"
    local rc=${PIPESTATUS[0]}
    [[ $rc -ne 0 ]] && log_msg "ERROR: zstd+dd failed" && return 1
    sync
    blockdev --flushbufs "$dst" 2>/dev/null || true
    return 0
}

# Determine write method based on image extension
IMAGE_EXT_LOWER=$(echo "$IMAGE_FILE" | tr '[:upper:]' '[:lower:]')

case "$IMAGE_EXT_LOWER" in
    *.raw.gz|*.img.gz)
        if ! write_image_gz "$IMAGE_FILE" "$TARGET_DISK"; then
            die_stage2 "Image write failed (gz)"
        fi
        ;;
    *.raw.zst|*.img.zst)
        if ! write_image_zst "$IMAGE_FILE" "$TARGET_DISK"; then
            die_stage2 "Image write failed (zst)"
        fi
        ;;
    *.raw|*.img)
        if ! write_image_raw "$IMAGE_FILE" "$TARGET_DISK"; then
            die_stage2 "Image write failed (raw)"
        fi
        ;;
    *.qcow2)
        log_msg "Converting qcow2 to raw..."
        qemu-img convert -O raw "$IMAGE_FILE" - | dd of="$TARGET_DISK" bs=4M conv=fsync status=progress 2>&1 | tee -a "$LOG"
        sync
        ;;
    *.iso)
        log_msg "Writing ISO in hybrid mode (dd)..."
        write_image_raw "$IMAGE_FILE" "$TARGET_DISK"
        ;;
    *)
        log_msg "Unknown format, trying raw write..."
        write_image_raw "$IMAGE_FILE" "$TARGET_DISK"
        ;;
esac

log_msg "=== IMAGE WRITTEN SUCCESSFULLY ==="

# -----------------------------------------------------------------
# Wait for partitions to appear
# -----------------------------------------------------------------
log_msg "Waiting for partitions to appear..."
sleep 3
blockdev --rereadpt "$TARGET_DISK" 2>/dev/null || true
udevadm settle 2>/dev/null || mdev -s 2>/dev/null || sleep 5

lsblk "$TARGET_DISK" >> "$LOG" 2>&1 || true

# Check firmware type (UEFI vs BIOS)
IS_UEFI=false
if [[ -d /sys/firmware/efi ]]; then
    IS_UEFI=true
    log_msg "Firmware: UEFI"
else
    log_msg "Firmware: BIOS (legacy)"
fi

# -----------------------------------------------------------------
# Detect OS type: Linux vs Windows
# -----------------------------------------------------------------
log_msg "=== DETECTING OS TYPE ==="

# Find all partitions on target disk
TARGET_PARTS=$(lsblk -nlo NAME,FSTYPE "${TARGET_DISK}" 2>/dev/null | grep -v "^$(basename "$TARGET_DISK") " || true)

# Try to find and mount a filesystem to detect OS
OS_TYPE="unknown"
ROOT_PART=""
EFI_PART=""

for pnum in 1 2 3 4 5; do
    # Try both naming conventions
    for part_dev in "${TARGET_DISK}${pnum}" "${TARGET_DISK}p${pnum}"; do
        if [[ -b "$part_dev" ]]; then
            local fstype
            fstype=$(blkid -s TYPE -o value "$part_dev" 2>/dev/null || echo "")

            # Detect EFI System Partition (FAT)
            if [[ "$fstype" == "vfat" ]]; then
                EFI_PART="$part_dev"
                log_msg "Found EFI System Partition: $EFI_PART"
                continue
            fi

            # Try to mount to detect OS
            if [[ -z "$ROOT_PART" ]]; then
                for mt in ext4 xfs btrfs ext3 ext2 ntfs ntfs3; do
                    if mount -t "$mt" -o ro "$part_dev" /mnt 2>/dev/null; then
                        ROOT_PART="$part_dev"
                        log_msg "Mounted $part_dev (type=$mt)"

                        # Detect OS type
                        if [[ -f /mnt/Windows/System32/ntoskrnl.exe ]] || \
                           [[ -f /mnt/Windows/System32/winload.exe ]] || \
                           [[ -f /mnt/Windows/System32/winload.efi ]]; then
                            OS_TYPE="windows"
                            log_msg "Detected: Windows"
                        elif [[ -f /mnt/etc/os-release ]] || [[ -f /mnt/etc/debian_version ]]; then
                            OS_TYPE="linux"
                            log_msg "Detected: Linux"
                        fi

                        umount /mnt 2>/dev/null || true
                        break 2
                    fi
                done
            fi
        fi
    done
done

# Also check common EFI paths
if [[ -z "$EFI_PART" && "$IS_UEFI" == "true" ]]; then
    for pnum in 1 2; do
        for part_dev in "${TARGET_DISK}${pnum}" "${TARGET_DISK}p${pnum}"; do
            if [[ -b "$part_dev" ]]; then
                local efifs
                efifs=$(blkid -s TYPE -o value "$part_dev" 2>/dev/null || echo "")
                if [[ "$efifs" == "vfat" ]]; then
                    EFI_PART="$part_dev"
                    log_msg "Found EFI partition (late scan): $EFI_PART"
                    break 2
                fi
            fi
        done
    done
fi

log_msg "OS type: $OS_TYPE | Root: ${ROOT_PART:-not found} | EFI: ${EFI_PART:-not found}"

# -----------------------------------------------------------------
# Mount new OS and finalize
# -----------------------------------------------------------------
log_msg "=== MOUNTING NEW OS ==="

if [[ -z "$ROOT_PART" ]]; then
    log_msg "WARNING: Could not find root partition. OS may still boot from its own bootloader."
else
    mount -o rw "$ROOT_PART" /mnt 2>/dev/null || {
        log_msg "Mount failed, trying auto filesystem detection..."
        for fstype in ext4 xfs btrfs ext3 ext2 ntfs ntfs3; do
            if mount -t "$fstype" -o rw "$ROOT_PART" /mnt 2>/dev/null; then
                log_msg "Mounted $ROOT_PART as $fstype"
                break
            fi
        done
    }

    if mountpoint -q /mnt 2>/dev/null; then
        log_msg "Successfully mounted new OS root at /mnt"

        # ----- LINUX: Regenerate initramfs + install GRUB -----
        if [[ "$OS_TYPE" == "linux" ]]; then
            mount -t proc proc /mnt/proc 2>/dev/null || true
            mount -t sysfs sysfs /mnt/sys 2>/dev/null || true
            mount -t devtmpfs devtmpfs /mnt/dev 2>/dev/null || true

            log_msg "Regenerating initramfs for new Linux OS..."
            if chroot /mnt update-initramfs -c -k all 2>/dev/null; then
                log_msg "update-initramfs completed"
            elif chroot /mnt dracut --regenerate-all --no-hostonly 2>/dev/null; then
                log_msg "dracut --regenerate-all completed"
            else
                log_msg "WARNING: Could not regenerate initramfs. New OS may fail to boot."
            fi

            log_msg "Installing GRUB to $TARGET_DISK..."
            if $IS_UEFI; then
                local efi_mountpoint="/mnt/boot/efi"
                if [[ -n "$EFI_PART" ]]; then
                    mkdir -p "$efi_mountpoint"
                    mount "$EFI_PART" "$efi_mountpoint" 2>/dev/null || true
                fi
                chroot /mnt grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=GRUB --removable 2>&1 | tee -a "$LOG" || \
                chroot /mnt grub2-install --target=x86_64-efi --efi-directory=/boot/efi --removable 2>&1 | tee -a "$LOG" || {
                    log_msg "WARNING: grub-install (UEFI) failed"
                }
                umount "$efi_mountpoint" 2>/dev/null || true
            else
                chroot /mnt grub-install --target=i386-pc "$TARGET_DISK" 2>&1 | tee -a "$LOG" || \
                chroot /mnt grub2-install --target=i386-pc "$TARGET_DISK" 2>&1 | tee -a "$LOG" || {
                    log_msg "WARNING: grub-install (BIOS) failed"
                }
            fi
            chroot /mnt update-grub 2>/dev/null || chroot /mnt grub-mkconfig -o /boot/grub/grub.cfg 2>/dev/null || true

            umount /mnt/proc 2>/dev/null || true
            umount /mnt/sys 2>/dev/null || true
            umount /mnt/dev 2>/dev/null || true

        # ----- WINDOWS: Handle bootloader for both BIOS and UEFI -----
        elif [[ "$OS_TYPE" == "windows" ]]; then
            log_msg "Windows OS detected"

            # Check if Windows bootloader files exist
            if [[ -f /mnt/Windows/System32/winload.efi ]] || [[ -f /mnt/Windows/System32/winload.exe ]]; then
                log_msg "Windows bootloader found: OK"
            fi
            if [[ -f /mnt/Windows/Boot/EFI/bootmgfw.efi ]]; then
                log_msg "Windows EFI Boot Manager found"
            fi

            if $IS_UEFI; then
                # === UEFI MODE: Image is MBR? Convert to GPT + create ESP ===
                log_msg "UEFI mode — checking partition table..."
                local pt_check
                pt_check=$(fdisk -l "$TARGET_DISK" 2>/dev/null | grep -i "disklabel type" | tr '[:upper:]' '[:lower:]')

                if echo "$pt_check" | grep -q "dos"; then
                    log_msg "Disk is MBR. Converting to GPT + creating EFI System Partition..."

                    # We need gdisk/sgdisk. If not in initramfs, we can do a minimal fix:
                    # Write protective MBR + create basic GPT with a small ESP at end
                    # Strategy: shrink last partition by 200MB, create ESP there

                    # Step 1: find last partition on disk
                    local last_part_end
                    last_part_end=$(fdisk -l "$TARGET_DISK" 2>/dev/null | grep "^${TARGET_DISK}" | awk 'END{print $3}')
                    [[ -z "$last_part_end" ]] && last_part_end=$(blockdev --getsz "$TARGET_DISK" 2>/dev/null)
                    log_msg "Last partition ends at sector: $last_part_end"

                    # Step 2: create EFI partition at end of disk (200MB)
                    local total_sectors efi_start efi_size_sectors
                    total_sectors=$(blockdev --getsz "$TARGET_DISK" 2>/dev/null || echo 0)
                    efi_size_sectors=$((200 * 1024 * 1024 / 512))   # 200MB in sectors
                    efi_start=$((total_sectors - efi_size_sectors))

                    if (( efi_start > last_part_end && total_sectors > 0 )); then
                        log_msg "Creating EFI partition: start=$efi_start size=200MB"

                        # Create using sfdisk (works on both MBR and GPT disks)
                        # First, convert to GPT
                        if command -v sgdisk &>/dev/null; then
                            sgdisk -g "$TARGET_DISK" 2>&1 | tee -a "$LOG"
                        fi

                        # Create EFI partition
                        echo "${efi_start},${efi_size_sectors},ef00" | sfdisk -a "$TARGET_DISK" 2>&1 | tee -a "$LOG" || {
                            log_msg "sfdisk failed, trying fdisk..."
                            printf "n\n\n\n+200M\nt\n1\nw\n" | fdisk "$TARGET_DISK" 2>&1 | tee -a "$LOG" || true
                        }

                        blockdev --rereadpt "$TARGET_DISK" 2>/dev/null || true
                        sleep 2

                        # Find the new EFI partition
                        local efi_dev=""
                        for pdev in "${TARGET_DISK}3" "${TARGET_DISK}4" "${TARGET_DISK}5" "${TARGET_DISK}p3" "${TARGET_DISK}p4"; do
                            if [[ -b "$pdev" ]]; then
                                efi_dev="$pdev"
                                break
                            fi
                        done

                        if [[ -n "$efi_dev" ]]; then
                            log_msg "EFI partition device: $efi_dev"
                            mkfs.vfat -F 32 -n "EFI" "$efi_dev" 2>&1 | tee -a "$LOG" || mkfs.fat -F 32 "$efi_dev" 2>&1 | tee -a "$LOG"

                            # Mount ESP and copy Windows boot files
                            mkdir -p /mnt2
                            if mount -t vfat "$efi_dev" /mnt2 2>/dev/null; then
                                mkdir -p /mnt2/EFI/BOOT
                                mkdir -p /mnt2/EFI/Microsoft/Boot

                                # Copy Windows boot files
                                if [[ -f /mnt/Windows/Boot/EFI/bootmgfw.efi ]]; then
                                    cp /mnt/Windows/Boot/EFI/bootmgfw.efi /mnt2/EFI/Microsoft/Boot/ 2>/dev/null
                                    cp /mnt/Windows/Boot/EFI/bootmgfw.efi /mnt2/EFI/BOOT/BOOTX64.EFI 2>/dev/null
                                    log_msg "Copied Windows EFI boot files to ESP"
                                fi
                                # Also copy other EFI files if present
                                cp /mnt/Windows/Boot/EFI/* /mnt2/EFI/Microsoft/Boot/ 2>/dev/null || true
                                # Copy boot resources
                                cp -r /mnt/Windows/Boot/Resources /mnt2/EFI/Microsoft/Boot/ 2>/dev/null || true
                                # Copy BCD
                                cp -r /mnt/Windows/Boot/DVD/EFI /mnt2/EFI/Microsoft/Boot/ 2>/dev/null || true

                                log_msg "ESP populated with Windows boot files"
                                log_msg "ESP contents:"
                                ls -laR /mnt2/ >> "$LOG" 2>&1
                                umount /mnt2 2>/dev/null
                            fi
                        fi
                    else
                        log_msg "Cannot create EFI partition — disk geometry issue"
                        log_msg "Trying alternative: write UEFI boot entry for existing bootloader"

                        # Direct efibootmgr: tell firmware to boot from disk
                        if command -v efibootmgr &>/dev/null; then
                            efibootmgr --create --disk "$TARGET_DISK" --part 1 \
                                --label "Windows" \
                                --loader "" 2>&1 | tee -a "$LOG" || true
                        fi
                    fi
                else
                    log_msg "Disk is already GPT — no conversion needed"

                    # Check if ESP exists on the image
                    if [[ -n "$EFI_PART" ]]; then
                        log_msg "EFI partition found: $EFI_PART"
                        mkdir -p /mnt2
                        if mount -t vfat "$EFI_PART" /mnt2 2>/dev/null; then
                            if [[ -f /mnt2/EFI/Microsoft/Boot/bootmgfw.efi ]]; then
                                log_msg "EFI boot manager present"
                            else
                                log_msg "Copying Windows boot files to existing ESP..."
                                mkdir -p /mnt2/EFI/BOOT /mnt2/EFI/Microsoft/Boot
                                [[ -f /mnt/Windows/Boot/EFI/bootmgfw.efi ]] && \
                                    cp /mnt/Windows/Boot/EFI/bootmgfw.efi /mnt2/EFI/BOOT/BOOTX64.EFI
                            fi
                            umount /mnt2 2>/dev/null
                        fi
                    fi
                fi

                # Register UEFI boot entry
                if command -v efibootmgr &>/dev/null && [[ -n "$EFI_PART" || -n "$efi_dev" ]]; then
                    local target_efi="${EFI_PART:-$efi_dev}"
                    local efi_partnum
                    efi_partnum=$(echo "$target_efi" | grep -oP '[0-9]+$')
                    efibootmgr --create --disk "$TARGET_DISK" --part "$efi_partnum" \
                        --label "Windows Boot Manager" \
                        --loader "\\EFI\\BOOT\\BOOTX64.EFI" 2>&1 | tee -a "$LOG" || true
                fi
            else
                # === BIOS/CSM MODE: Verify MBR ===
                log_msg "BIOS mode: verifying MBR boot signature..."
                local mbr_sig
                mbr_sig=$(dd if="$TARGET_DISK" bs=1 skip=510 count=2 2>/dev/null | od -An -tx1 | tr -d ' ')
                if [[ "$mbr_sig" == "55aa" ]]; then
                    log_msg "MBR signature valid (55 AA) — should boot"
                else
                    log_msg "WARNING: MBR signature missing — disk may not boot"
                    # Write boot signature
                    printf '\x55\xaa' | dd of="$TARGET_DISK" bs=1 seek=510 conv=notrunc 2>/dev/null
                    log_msg "MBR signature written"
                fi
            fi

        # ----- UNKNOWN: Just log -----
        else
            log_msg "Unknown OS type — image should boot from its own bootloader"
        fi

        umount /mnt 2>/dev/null || true
    else
        log_msg "WARNING: Could not mount root partition. Image should boot from its own bootloader."
        # Still try to register UEFI entry if we found the ESP
        if $IS_UEFI && [[ -n "$EFI_PART" ]]; then
            log_msg "Found EFI partition — firmware should auto-detect it"
        fi
    fi
fi

# -----------------------------------------------------------------
# Reboot into new OS
# -----------------------------------------------------------------
log_msg "=== REBOOTING INTO NEW OS ==="
log_msg "Install log saved. System will reboot in 5 seconds..."

sync
sleep 5

# Try various reboot methods
reboot -f 2>/dev/null || reboot 2>/dev/null || echo b > /proc/sysrq-trigger 2>/dev/null || true

die_stage2() {
    log_msg "FATAL: $*"
    log_msg "System will not reboot. Connect to console to debug."
    while true; do sleep 60; done
}

log_msg "Reboot command sent. If stuck, manually reboot."
while true; do sleep 60; done
STAGE2INIT

    chmod +x "$tmpdir/init"

    # Copy essential tools
    for tool in dd lsblk blkid findfs mount umount chroot sync blockdev; do
        if command -v "$tool" &>/dev/null; then
            cp "$(command -v "$tool")" "$tmpdir/bin/" 2>/dev/null || true
        fi
    done

    # Copy sha256sum
    if command -v sha256sum &>/dev/null; then
        cp "$(command -v sha256sum)" "$tmpdir/bin/" 2>/dev/null || true
    fi

    # Copy zstd, gunzip, xz if present
    for tool in zstd gunzip xz bzip2 qemu-img; do
        if command -v "$tool" &>/dev/null; then
            cp "$(command -v "$tool")" "$tmpdir/bin/" 2>/dev/null || true
        fi
    done

    # Copy required libraries for the tools we added (POSIX-safe, no grep -P)
    if command -v ldd &>/dev/null; then
        local libs
        libs=$(ldd "$tmpdir/bin/dd" "$tmpdir/bin/zstd" "$tmpdir/bin/gunzip" 2>/dev/null | awk '/=>/ {print $3}' | sort -u || true)
        # Also catch ld-linux style entries
        libs="$libs $(ldd "$tmpdir/bin/dd" "$tmpdir/bin/zstd" 2>/dev/null | awk 'NF==4 && $2!="=>" {print $1}' | sort -u || true)"
        libs="$libs $(ldconfig -p 2>/dev/null | awk 'NR>1 {print $NF}' | grep -E '(libc\.so|libz\.so|liblzma\.so|liblz4\.so|libpthread)' | sort -u || true)"

        for lib in $libs; do
            if [[ -f "$lib" ]]; then
                mkdir -p "$tmpdir/$(dirname "$lib")"
                cp -L "$lib" "$tmpdir/$lib" 2>/dev/null || true
            fi
        done
    fi

    # Also ensure standard lib directories — support both Debian and EL layouts
    local lib_dirs=( "/lib/x86_64-linux-gnu" "/lib64" "/usr/lib/x86_64-linux-gnu" "/usr/lib64" )
    for lib_dir in "${lib_dirs[@]}"; do
        if [[ -d "$lib_dir" ]]; then
            mkdir -p "$tmpdir/$lib_dir"
            cp -L "$lib_dir"/libc.so*      "$tmpdir/$lib_dir/" 2>/dev/null || true
            cp -L "$lib_dir"/libz.so*      "$tmpdir/$lib_dir/" 2>/dev/null || true
            cp -L "$lib_dir"/liblzma.so*   "$tmpdir/$lib_dir/" 2>/dev/null || true
            cp -L "$lib_dir"/liblz4.so*    "$tmpdir/$lib_dir/" 2>/dev/null || true
            cp -L "$lib_dir"/libpthread*   "$tmpdir/$lib_dir/" 2>/dev/null || true
            cp -L "$lib_dir"/libdl.so*     "$tmpdir/$lib_dir/" 2>/dev/null || true
            cp -L "$lib_dir"/libm.so*      "$tmpdir/$lib_dir/" 2>/dev/null || true
        fi
    done

    # Build cpio archive
    log_info "Building cpio archive..."
    (
        cd "$tmpdir"
        find . -print0 | cpio --null --create --format=newc 2>/dev/null | gzip > "$STAGE2_INITRD"
    )

    if [[ -f "$STAGE2_INITRD" ]]; then
        local initrd_size
        initrd_size=$(stat -c%s "$STAGE2_INITRD")
        log_success "Stage 2 initramfs built: $STAGE2_INITRD ($((initrd_size/1024)) KB)"
    else
        die "Failed to build Stage 2 initramfs"
    fi

    rm -rf "$tmpdir"
}

if ! $DRY_RUN; then
    build_stage2_initramfs
fi

# ---------------------------------------------------------------------------
# PHASE 8: GRUB Configuration
# ---------------------------------------------------------------------------
banner "Phase 8: GRUB configuration"

find_grub_cfg() {
    if [[ "$FIRMWARE" == "uefi" ]]; then
        # Find EFI GRUB config
        for path in /boot/efi/EFI/*/grub.cfg /boot/grub/grub.cfg /boot/grub2/grub.cfg; do
            if [[ -f "$path" ]]; then
                echo "$path"
                return
            fi
        done
    else
        # BIOS GRUB
        for path in /boot/grub2/grub.cfg /boot/grub/grub.cfg; do
            if [[ -f "$path" ]]; then
                echo "$path"
                return
            fi
        done
    fi
    echo ""
}

GRUB_CFG=$(find_grub_cfg)
if [[ -z "$GRUB_CFG" ]]; then
    die "Could not find grub.cfg. Check your GRUB installation."
fi
log_info "GRUB config: $GRUB_CFG"

# Backup original GRUB config
if ! $DRY_RUN; then
    cp "$GRUB_CFG" "${GRUB_CFG}.osreinstall.bak"
    log_info "Backed up GRUB config to ${GRUB_CFG}.osreinstall.bak"
fi

# Remove any existing osreinstall entry
remove_existing_entry() {
    local cfg="$1"
    # Remove the menuentry block between our markers
    sed -i '/^### BEGIN OSREINSTALL ###/,/^### END OSREINSTALL ###/d' "$cfg"
}

# Build the GRUB entry
build_grub_entry() {
    local checksum
    checksum=$(cut -d' ' -f1 "$STAGE2_IMAGE_CHECKSUM" 2>/dev/null || echo "")

    # Get the partition that actually holds STAGE2_DIR (usually the root fs,
    # NOT /boot — see comment near the STAGE2_DIR definition) for file search
    local search_directive
    search_directive="search --no-floppy --file --set=root /${STAGE2_GRUB_REL}/osreinstall-disk.img"

    # Try UUID as fallback
    local data_uuid=""
    local data_dev=""
    if command -v findmnt &>/dev/null; then
        data_dev=$(findmnt -n -o SOURCE --target "$STAGE2_DIR" 2>/dev/null || findmnt -n -o SOURCE / 2>/dev/null)
    fi
    if [[ -n "$data_dev" ]]; then
        data_uuid=$(blkid -s UUID -o value "$data_dev" 2>/dev/null || echo "")
    fi
    if [[ -n "$data_uuid" ]]; then
        # NOTE: use an actual newline ($'\n'), NOT the literal two-char "\n" —
        # the latter does not expand inside a plain double-quoted string and
        # ends up cramming two GRUB commands onto a single config line,
        # corrupting parsing ("no such device", ".mod not found" errors).
        search_directive="${search_directive}"$'\n'"    search --no-floppy --fs-uuid --set=root $data_uuid"
    fi

    # Firmware-specific GRUB modules
    local firmware_modules=""
    if [[ "$FIRMWARE" == "uefi" ]]; then
        firmware_modules="insmod efi_gop"$'\n'"    insmod efi_uga"
    else
        firmware_modules="insmod biosdisk"$'\n'"    insmod vbe"
    fi

    # Build kernel boot line based on mode (loopback vs host kernel)
    local kernel_line=""
    local initrd_line=""
    local extra_insmod=""

    if $USE_LOOPBACK; then
        # === GRUB LOOPBACK MODE (TinyInstaller-style) ===
        # GRUB mounts the raw image as a loop device and boots kernel FROM INSIDE
        extra_insmod="insmod loopback"
        kernel_line="linux (loop)${LOOPBACK_KERNEL} \\
        target_disk=${TARGET_DISK} \\
        image_file=/${STAGE2_GRUB_REL}/osreinstall-disk.img \\
        data_fs_uuid=${data_uuid} \\
        image_checksum=${checksum} \\
        image_format=${IMAGE_EXT} \\
        console=tty0 console=ttyS0,115200n8 \\
        osreinstall_debug=1"

        initrd_line="initrd (loop)${LOOPBACK_INITRD}"
    else
        # === HOST KERNEL MODE (our custom initramfs) ===
        extra_insmod=""
        kernel_line="linux /${STAGE2_GRUB_REL}/osreinstall-vmlinuz \\
        target_disk=${TARGET_DISK} \\
        image_file=/${STAGE2_GRUB_REL}/osreinstall-disk.img \\
        image_checksum=${checksum} \\
        image_format=${IMAGE_EXT} \\
        data_fs_uuid=${data_uuid} \\
        console=tty0 console=ttyS0,115200n8 \\
        osreinstall_debug=1"

        initrd_line="initrd /${STAGE2_GRUB_REL}/osreinstall-initrd.img"
    fi

    cat <<GRUBENTRY

### BEGIN OSREINSTALL ###
menuentry "${GRUB_MENU_TITLE}" --id ${GRUB_MENU_ID} {
    insmod part_msdos
    insmod part_gpt
    insmod ext2
    insmod ext4
    insmod xfs
    insmod btrfs
    insmod gzio
    insmod zstd
    insmod normal
    insmod linux
    ${firmware_modules}
    ${extra_insmod}

    # Find boot partition containing image/kernel files
    ${search_directive}

    echo 'Loading OS Reinstaller kernel...'
    ${kernel_line}

    echo 'Loading OS Reinstaller initramfs...'
    ${initrd_line}
}
### END OSREINSTALL ###
GRUBENTRY
}

if ! $DRY_RUN; then
    remove_existing_entry "$GRUB_CFG"

    # Build the entry and INSERT AT TOP of grub.cfg (before first menuentry)
    entry_file=$(mktemp)
    build_grub_entry > "$entry_file"

    first_menu_line=$(grep -nm1 '^menuentry ' "$GRUB_CFG" | cut -d: -f1)
    if [[ -n "$first_menu_line" ]]; then
        head -n $((first_menu_line - 1)) "$GRUB_CFG" > "${GRUB_CFG}.tmp"
        cat "$entry_file" >> "${GRUB_CFG}.tmp"
        tail -n +${first_menu_line} "$GRUB_CFG" >> "${GRUB_CFG}.tmp"
        mv "${GRUB_CFG}.tmp" "$GRUB_CFG"
        log_success "GRUB entry inserted as FIRST boot entry"
    else
        cat "$entry_file" >> "$GRUB_CFG"
        log_success "GRUB entry appended (no existing menuentries found)"
    fi
    rm -f "$entry_file"

    # Ensure GRUB shows menu (set timeout to 5s if currently 0)
    if [[ -f /etc/default/grub ]]; then
        if grep -q '^GRUB_TIMEOUT=0' /etc/default/grub 2>/dev/null; then
            cp /etc/default/grub /etc/default/grub.osreinstall.bak
            sed -i 's/^GRUB_TIMEOUT=0/GRUB_TIMEOUT=5/' /etc/default/grub
            log_info "GRUB timeout set to 5s (was 0)"
        fi
    fi

    log_success "GRUB entry written to $GRUB_CFG"
fi

# ---------------------------------------------------------------------------
# PHASE 9: Final confirmation
# ---------------------------------------------------------------------------
banner "Phase 9: Confirmation"

echo ""
echo "  ╔═══════════════════════════════════════════════════════════════╗"
echo "  ║                    OS REINSTALLER SUMMARY                     ║"
echo "  ╠═══════════════════════════════════════════════════════════════╣"
printf "  ║  Target Disk:   %-46s ║\n" "$TARGET_DISK"
printf "  ║  Disk Size:     %-43s GB ║\n" "$DISK_SIZE_GB"
printf "  ║  Image URL:     %-46s ║\n" "${IMAGE_URL:0:46}"
printf "  ║  Image Format:  %-46s ║\n" "${IMAGE_EXT}${COMPRESSION:+ ($COMPRESSION)}"
printf "  ║  Firmware:      %-46s ║\n" "${FIRMWARE^^}"
printf "  ║  Hypervisor:    %-46s ║\n" "${HYPERVISOR}"
echo "  ╠═══════════════════════════════════════════════════════════════╣"
echo "  ║  ⚠ WARNING: All data on $TARGET_DISK will be DESTROYED!      ║"
echo "  ╚═══════════════════════════════════════════════════════════════╝"
echo ""

if $DRY_RUN; then
    log_info "[DRY RUN] Would NOT write to disk. Use without --dry-run to proceed."
    exit 0
fi

echo -n "${RED}Type 'YES' (uppercase) to confirm and reboot: ${NC}"
read -r CONFIRM1
if [[ "$CONFIRM1" != "YES" ]]; then
    log_info "Aborted by user."
    remove_existing_entry "$GRUB_CFG"
    exit 0
fi

echo -n "${RED}Are you absolutely sure? Type the disk name ($(basename "$TARGET_DISK")) to confirm: ${NC}"
read -r CONFIRM2
if [[ "$CONFIRM2" != "$(basename "$TARGET_DISK")" ]]; then
    log_info "Aborted by user (disk name mismatch)."
    remove_existing_entry "$GRUB_CFG"
    exit 0
fi

# ---------------------------------------------------------------------------
# PHASE 10: Set GRUB default and reboot
# ---------------------------------------------------------------------------
banner "Phase 10: Reboot into installer"

log_info "Setting GRUB to boot OS Reinstaller..."

# Method 1: grub-reboot (one-time boot, requires GRUB_DEFAULT=saved)
# This writes "osreinstall" to /boot/grub/grubenv next_entry
if grub-reboot "$GRUB_MENU_ID" 2>/dev/null; then
    log_success "grub-reboot set: will boot $GRUB_MENU_ID once, then revert"
else
    # Method 2: grub-set-default (permanent, but stage2 will overwrite disk anyway)
    log_warn "grub-reboot failed, using grub-set-default instead"
    if grub-set-default "$GRUB_MENU_ID" 2>/dev/null; then
        log_success "grub-set-default set to $GRUB_MENU_ID"
    else
        # Method 3: direct grubenv edit (last resort)
        log_warn "grub-set-default failed, editing grubenv directly"
        grub-editenv /boot/grub/grubenv set saved_entry="$GRUB_MENU_ID" 2>/dev/null || true
        grub-editenv /boot/grub/grubenv set next_entry="$GRUB_MENU_ID" 2>/dev/null || true
    fi
fi

# Also try grub2- variants (RHEL/CentOS)
grub2-reboot "$GRUB_MENU_ID" 2>/dev/null || true
grub2-set-default "$GRUB_MENU_ID" 2>/dev/null || true

log_success "GRUB configured for one-time boot into installer"
log_info "To verify: cat /boot/grub/grubenv | grep -E 'saved_entry|next_entry'"

if $NO_REBOOT; then
    log_info ""
    log_info "=== NO-REBOOT MODE: Script complete, NOT rebooting ==="
    log_info "GRUB entry written to: $GRUB_CFG"
    log_info "Next manual reboot will boot into OS Reinstaller"
    log_info ""
    log_info "To trigger manually:"
    log_info "  grub-reboot $GRUB_MENU_ID && reboot"
    log_info ""
    log_info "To test GRUB entry without rebooting:"
    log_info "  grep -A20 'BEGIN OSREINSTALL' $GRUB_CFG"
    exit 0
fi

log_info "Rebooting in 3 seconds..."
sleep 3

# Try all reboot methods
reboot 2>/dev/null || \
shutdown -r now 2>/dev/null || \
systemctl reboot 2>/dev/null || \
/sbin/reboot 2>/dev/null || \
echo b > /proc/sysrq-trigger 2>/dev/null || \
reboot -f 2>/dev/null || \
{
    log_error "All reboot methods failed. Please reboot manually."
    log_info "System should boot into OS Reinstaller automatically on next boot."
    exit 1
}

# Should not reach here
exit 0

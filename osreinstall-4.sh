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
readonly STAGE2_INITRD="/boot/osreinstall-initrd.img"
readonly STAGE2_KERNEL="/boot/osreinstall-vmlinuz"
readonly STAGE2_IMAGE="/boot/osreinstall-disk.img"
readonly STAGE2_IMAGE_CHECKSUM="/boot/osreinstall-disk.img.sha256"
readonly STAGE2_IMAGE_SIZE="/boot/osreinstall-disk.img.size"
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
        --no-reboot) NO_REBOOT=true; shift ;;
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

# Check free space in /boot
BOOT_FREE=$(df -m /boot 2>/dev/null | awk 'NR==2 {print $4}' || df -m / | awk 'NR==2 {print $4}')
BOOT_FREE_GB=$((BOOT_FREE / 1024))
log_info "Free space in /boot: ${BOOT_FREE} MB (${BOOT_FREE_GB} GB)"

# Download with retry + resume support
download_image() {
    local url="$1"
    local dest="$2"
    local retries=3

    for attempt in $(seq 1 $retries); do
        log_info "Download attempt $attempt/$retries..."

        # Use wget with resume (-c) support
        if wget --no-check-certificate -4 -c --progress=bar:force:noscroll \
            -O "$dest" "$url" 2>&1 | tee -a "$LOGFILE"; then
            log_success "Download completed (wget)"
            return 0
        fi

        if curl -L -C - --progress-bar -o "$dest" "$url" 2>&1 | tee -a "$LOGFILE"; then
            log_success "Download completed (curl)"
            return 0
        fi

        if (( attempt < retries )); then
            log_warn "Download failed, retrying in 5 seconds..."
            sleep 5
            # Keep partial file for resume — DON'T delete
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
# PHASE 7: Prepare Stage 2 kernel & initramfs
# ---------------------------------------------------------------------------
banner "Phase 7: Prepare Stage 2 (kernel + initramfs)"

# We re-use the host kernel for Stage 2 (it should have all virt drivers)
# BUT we generate a fresh, generic initramfs for Stage 2 that includes
# our install script. This initramfs must NOT be host-only.

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
log_info "Kernel image: $KERNEL_IMAGE"

# Copy kernel to known location for GRUB
if ! $DRY_RUN; then
    cp "$KERNEL_IMAGE" "$STAGE2_KERNEL"
    log_success "Copied kernel to $STAGE2_KERNEL"
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

echo "" > /dev/ttyS0 2>/dev/null || true
exec >/dev/ttyS0 2>&1 </dev/ttyS0 || true

LOG="/run/install.log"
:> "$LOG"

log_msg() {
    local ts
    ts=$(cat /proc/uptime | cut -d. -f1)
    echo "[${ts}s] $*" | tee -a "$LOG"
    echo "[${ts}s] $*" > /dev/console 2>/dev/null || true
}

log_msg "=== OS Reinstaller Stage 2 Starting ==="
log_msg "Uptime: $(cat /proc/uptime)"

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
IMAGE_FILE=$(extract_param "image_file" "/os-image.img")
IMAGE_CHECKSUM=$(extract_param "image_checksum" "")
IMAGE_FORMAT=$(extract_param "image_format" "raw")
STAGE2_DEBUG=$(extract_param "osreinstall_debug" "")

log_msg "Target disk: ${TARGET_DISK:-auto}"
log_msg "Image file:  $IMAGE_FILE"
log_msg "Image format: $IMAGE_FORMAT"

# -----------------------------------------------------------------
# Mount /boot to access image file
# -----------------------------------------------------------------
MOUNTED_BOOT=false
if mount /boot 2>/dev/null; then
    MOUNTED_BOOT=true
    log_msg "Mounted /boot"
elif mount /dev/sda1 /boot 2>/dev/null; then
    MOUNTED_BOOT=true
    log_msg "Mounted /dev/sda1 to /boot"
elif mount /dev/vda1 /boot 2>/dev/null; then
    MOUNTED_BOOT=true
    log_msg "Mounted /dev/vda1 to /boot"
elif mount /dev/nvme0n1p1 /boot 2>/dev/null; then
    MOUNTED_BOOT=true
    log_msg "Mounted /dev/nvme0n1p1 to /boot"
elif mount /dev/xvda1 /boot 2>/dev/null; then
    MOUNTED_BOOT=true
    log_msg "Mounted /dev/xvda1 to /boot"
else
    # Try to find and mount any ext4/xfs partition that might be /boot
    for dev in /dev/sd[a-z]1 /dev/vd[a-z]1 /dev/nvme[0-9]n[0-9]p1 /dev/xvd[a-z]1; do
        if mount -t ext4 "$dev" /boot 2>/dev/null; then
            MOUNTED_BOOT=true
            log_msg "Mounted $dev to /boot"
            break
        fi
        if mount -t xfs "$dev" /boot 2>/dev/null; then
            MOUNTED_BOOT=true
            log_msg "Mounted $dev to /boot"
            break
        fi
    done
fi

if ! $MOUNTED_BOOT; then
    log_msg "WARNING: Could not mount /boot. Image must be accessible at $IMAGE_FILE"
fi

# -----------------------------------------------------------------
# Verify image file exists
# -----------------------------------------------------------------
if [[ ! -f "$IMAGE_FILE" ]]; then
    log_msg "ERROR: Image file not found at $IMAGE_FILE"
    log_msg "Contents of /boot:"
    ls -la /boot/ 2>/dev/null >> "$LOG"
    log_msg "Contents of /:"
    ls -la / >> "$LOG"

    # Fallback: try common paths
    for candidate in /boot/osreinstall-disk.img /boot/*.img /boot/*.raw* /osreinstall-disk.img; do
        if [[ -f "$candidate" ]]; then
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

        # ----- WINDOWS: Check bootloader integrity, register UEFI entry -----
        elif [[ "$OS_TYPE" == "windows" ]]; then
            log_msg "Windows OS detected — skipping Linux initramfs/GRUB steps"

            # Verify Windows bootloader exists
            WIN_BOOTLOADER=""
            if [[ -f /mnt/Windows/System32/winload.efi ]] || [[ -f /mnt/Windows/System32/winload.exe ]]; then
                log_msg "Windows bootloader found: OK"
                WIN_BOOTLOADER="/mnt/Windows/System32/winload.efi"
            fi

            if [[ -f /mnt/Windows/Boot/EFI/bootmgfw.efi ]]; then
                log_msg "Windows Boot Manager found: OK"
            fi

            # For UEFI: try to register Windows boot entry
            if $IS_UEFI && [[ -n "$EFI_PART" ]]; then
                log_msg "Registering Windows UEFI boot entry..."
                mkdir -p /mnt2
                if mount -t vfat "$EFI_PART" /mnt2 2>/dev/null; then
                    # Verify EFI boot file exists
                    if [[ -f /mnt2/EFI/Microsoft/Boot/bootmgfw.efi ]]; then
                        log_msg "Found Windows EFI boot manager"
                        # Try efibootmgr to register the entry
                        if command -v efibootmgr &>/dev/null; then
                            efibootmgr --create --disk "$TARGET_DISK" --part "${EFI_PART##*[!0-9]}" \
                                --label "Windows Boot Manager" \
                                --loader "\\EFI\\Microsoft\\Boot\\bootmgfw.efi" 2>&1 | tee -a "$LOG" || \
                            log_msg "WARNING: efibootmgr failed — firmware may auto-detect the EFI entry"
                        fi
                    elif [[ -f /mnt2/EFI/BOOT/BOOTX64.EFI ]]; then
                        log_msg "Found fallback EFI bootloader (BOOTX64.EFI)"
                    else
                        log_msg "WARNING: No EFI bootloader found on ESP"
                        ls -laR /mnt2/EFI/ >> "$LOG" 2>&1 || true
                    fi
                    umount /mnt2 2>/dev/null || true
                fi
            elif ! $IS_UEFI; then
                # BIOS/MBR: verify MBR has valid boot code
                log_msg "BIOS boot: verifying MBR signature..."
                local mbr_sig
                mbr_sig=$(dd if="$TARGET_DISK" bs=1 skip=510 count=2 2>/dev/null | od -An -tx1 | tr -d ' ')
                if [[ "$mbr_sig" == "55aa" ]]; then
                    log_msg "MBR signature valid (55 AA)"
                else
                    log_msg "WARNING: MBR signature missing or invalid"
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
    for tool in dd lsblk blkid mount umount chroot sync blockdev; do
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

    # Determine boot partition UUID — use multiple fallbacks
    local boot_uuid=""
    local boot_dev

    # Method 1: findmnt (most reliable)
    if command -v findmnt &>/dev/null; then
        boot_dev=$(findmnt -n -o SOURCE /boot 2>/dev/null || findmnt -n -o SOURCE / 2>/dev/null)
    fi
    # Method 2: df fallback
    if [[ -z "$boot_dev" ]]; then
        boot_dev=$(df --output=source /boot 2>/dev/null | tail -1 || df --output=source / 2>/dev/null | tail -1)
    fi

    if [[ -n "$boot_dev" ]]; then
        boot_uuid=$(blkid -s UUID -o value "$boot_dev" 2>/dev/null || echo "")
    fi

    # Build GRUB search directive
    local search_directive
    if [[ -n "$boot_uuid" && "$boot_uuid" != "" ]]; then
        search_directive="search --no-floppy --fs-uuid --set=root $boot_uuid"
    else
        # Fallback: search for known files
        search_directive="search --no-floppy --file --set=root /osreinstall-vmlinuz"
    fi

    # Firmware-specific GRUB modules
    local firmware_modules=""
    if [[ "$FIRMWARE" == "uefi" ]]; then
        firmware_modules="insmod efi_gop\n    insmod efi_uga\n    insmod linuxefi"
    else
        firmware_modules="insmod biosdisk\n    insmod vbe"
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
    insmod loopback
    insmod normal
    insmod linux
    ${firmware_modules}

    # Search for the boot partition
    ${search_directive}

    echo 'Loading OS Reinstaller kernel...'
    linux /osreinstall-vmlinuz \\
        target_disk=${TARGET_DISK} \\
        image_file=/osreinstall-disk.img \\
        image_checksum=${checksum} \\
        image_format=${IMAGE_EXT} \\
        console=tty0 console=ttyS0,115200n8 \\
        osreinstall_debug=1

    echo 'Loading OS Reinstaller initramfs...'
    initrd /osreinstall-initrd.img
}
### END OSREINSTALL ###
GRUBENTRY
}

if ! $DRY_RUN; then
    remove_existing_entry "$GRUB_CFG"
    build_grub_entry | tee -a "$GRUB_CFG" > /dev/null
    log_success "GRUB entry added to $GRUB_CFG"
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
# PHASE 10: Set grub-reboot and reboot
# ---------------------------------------------------------------------------
banner "Phase 10: Reboot into installer"

# Use grub-reboot for one-time boot into our entry
# This ensures that if Stage 2 fails, the system boots back to original OS
log_info "Setting grub-reboot to '${GRUB_MENU_ID}'..."
grub-reboot "$GRUB_MENU_ID" 2>/dev/null || {
    log_warn "grub-reboot failed. Setting default boot entry instead."
    grub-set-default "$GRUB_MENU_ID" 2>/dev/null || true
}

# Also try grub2-reboot (RHEL/CentOS naming)
grub2-reboot "$GRUB_MENU_ID" 2>/dev/null || true

log_success "GRUB configured for one-time boot into installer"

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

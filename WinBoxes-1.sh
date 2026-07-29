#!/bin/bash
# ============================================================================
#  WinBoxes  —  Windows disk-image deployer
# ----------------------------------------------------------------------------
#  Faithful bash re-implementation of the TinyInstaller *flow*, combined with
#  the netboot 2-stage technique (custom initramfs that dd's the image after
#  reboot) demonstrated by community tools (winhost / reinstall).
#
#  TinyInstaller is a SAAS *netboot* installer: its Windows image list is
#  fetched at runtime from https://tinyinstaller.top (authenticated), the
#  actual write happens inside a GRUB-loop-booted initramfs. WinBoxes replaces
#  the SAAS list with a static 6-entry table (archive.org .img URLs) and uses a
#  self-built initramfs that dd's the image to disk — same end result, no
#  server dependency.
#
#  Flow (mirrors TinyInstaller step-for-step):
#     1. preflight  (root / arch / container / OS / live-boot)
#     2. "Checking system information..."  (UEFI, provider, IP)
#     3. "Please select a profile."  -> OS image menu (6 entries)
#     4. disk auto-select / lsblk list / --disk
#     5. firmware consistency check (USE_UEFI vs host firmware)
#     6. "Are you sure you want to deploy on this disk?"
#     7. download image  (wget -> curl, aria2c if available)
#     8. build Stage-2 initramfs (busybox + embedded init that dd's)
#     9. write GRUB menuentry + grub-reboot
#    10. show IPv4, "Continue Reboot (Y/n)", reboot
#        -> after reboot: GRUB boots our kernel+initramfs, init dd's image,
#           fixes UEFI/BIOS boot, reboots into Windows.
# ============================================================================

export LANG=C
export PATH="/usr/sbin:/usr/bin:/sbin:/bin:$PATH"
readonly TOOL_NAME="WinBoxes"
readonly GRUB_MENU_ID="winboxes"
readonly GRUB_MENU_TITLE="WinBoxes"
readonly VERSION="2.0-netboot"

# Stage-2 data lives on root fs (NOT /boot — many VPS have tiny /boot).
readonly STAGE2_DIR="/winboxes-data"
readonly STAGE2_INITRD="${STAGE2_DIR}/winboxes-initrd.img"
readonly STAGE2_KERNEL="${STAGE2_DIR}/winboxes-vmlinuz"
readonly STAGE2_IMAGE="${STAGE2_DIR}/winboxes-disk.img"
readonly STAGE2_IMAGE_CHECKSUM="${STAGE2_DIR}/winboxes-disk.img.sha256"
readonly STAGE2_IMAGE_SIZE="${STAGE2_DIR}/winboxes-disk.img.size"
readonly STAGE2_GRUB_REL="${STAGE2_DIR#/}"
readonly LOGFILE="/var/log/winboxes.log"

# ---------------------------------------------------------------------------
#  ANSI colour helpers — TinyInstaller emits <green>/<cyan>/<red>/<yellow>.
# ---------------------------------------------------------------------------
if [ -t 1 ]; then
    C_GREEN=$'\033[32m'; C_CYAN=$'\033[36m'; C_RED=$'\033[31m'
    C_YELLOW=$'\033[33m'; C_BOLD=$'\033[1m'; C_RESET=$'\033[0m'
else
    C_GREEN=""; C_CYAN=""; C_RED=""; C_YELLOW=""; C_BOLD=""; C_RESET=""
fi
green()  { printf '%s%s%s' "$C_GREEN"  "$*" "$C_RESET"; }
cyan()   { printf '%s%s%s' "$C_CYAN"   "$*" "$C_RESET"; }
red()    { printf '%s%s%s' "$C_RED"    "$*" "$C_RESET"; }
yellow() { printf '%s%s%s' "$C_YELLOW" "$*" "$C_RESET"; }
bold()   { printf '%s%s%s' "$C_BOLD"   "$*" "$C_RESET"; }

log()        { echo -e "$*" | tee -a "$LOGFILE"; }
log_info()   { log "[INFO]  $*"; }
log_warn()   { log "${C_YELLOW}[WARN]  $*${C_RESET}"; }
log_error()  { log "${C_RED}[ERROR] $*${C_RESET}"; }
log_success(){ log "${C_GREEN}[OK]    $*${C_RESET}"; }
die()        { log_error "$@"; exit 1; }

# ===========================================================================
#  STEP 0 — re-exec under bash, then under sudo  (mirrors setup.sh:3-10)
# ===========================================================================
if [ -z "$BASH" ]; then bash "$0" "$@"; exit 0; fi
if [ "$(id -u)" != "0" ]; then sudo bash "$0" "$@"; exit $?; fi

# Parse CLI options up-front.
TARGET_DISK=""
IMAGE_CHOICE=""
DRY_RUN=false
NO_REBOOT=false
while [ $# -gt 0 ]; do
    case "$1" in
        --disk)     TARGET_DISK="$2";  shift 2 ;;
        --image)    IMAGE_CHOICE="$2"; shift 2 ;;
        --dry-run)  DRY_RUN=true;  shift ;;
        --no-reboot) NO_REBOOT=true; shift ;;
        --help|-h)
            cat <<EOF
Usage: $0 [options]
  --image <N>     Pre-select image 1..6 (non-interactive)
  --disk <DEV>    Target disk (e.g. /dev/sda). Default: auto-select largest.
  --dry-run       Validate only, do not write or reboot.
  --no-reboot     Prepare everything but do not reboot.
  --help          Show this help.
EOF
            exit 0 ;;
        *) die "Unknown option: $1 (use --help)" ;;
    esac
done

mkdir -p "$(dirname "$LOGFILE")"; : > "$LOGFILE"
mkdir -p "$STAGE2_DIR"

# ===========================================================================
#  STEP 1 — preflight environment checks  (mirrors setup.sh:11-87 + Go client)
# ===========================================================================
# 1a. Architecture: TinyInstaller rejects aarch64
if [ "$(uname -m)" = "aarch64" ]; then echo "$(red 'ARM is not supported!')"; exit 1; fi
if [ "$(uname -m)" != "x86_64" ]; then die "Unsupported architecture: $(uname -m). Only x86_64."; fi

# 1b. Dependency bootstrap — apt/dnf/yum (setup.sh:15-30)
if ! command -v wget > /dev/null || ! command -v lsblk > /dev/null \
    || ! command -v fdisk > /dev/null || ! command -v ip > /dev/null; then
    if command -v apt >/dev/null 2>&1; then
        apt --quiet --yes update || true
        apt --quiet --yes install iproute2 wget fdisk curl grub2-common busybox-static cpio systemd systemd-sysv 2>/dev/null || true
    elif command -v dnf >/dev/null 2>&1; then
        for p in iproute2 wget fdisk util-linux curl grub2-common busybox cpio systemd; do dnf --quiet --assumeyes install "$p" 2>/dev/null || true; done
    elif command -v yum >/dev/null 2>&1; then
        for p in iproute2 wget fdisk util-linux curl grub2-common busybox cpio systemd; do yum --quiet --assumeyes install "$p" 2>/dev/null || true; done
    fi
fi

# 1c. Required tools (setup.sh:32-59)
#     cpio is REQUIRED to build the Stage-2 initramfs — without it the
#     archive is empty → kernel panic "No working init found".
for t in ip wget lsblk blkid fdisk base64 cpio mount umount sync blockdev; do
    command -v "$t" > /dev/null || die "Required tool '$t' not found. Install it and retry."
done

# 1c-bis. Ensure systemd is available
#   WinBoxes uses systemctl (firewall management, reboot) and
#   systemd-detect-virt (container detection). Many minimal / custom VPS
#   images ship WITHOUT systemd (using sysvinit, OpenRC, or a bare shell
#   as PID 1). This step auto-installs systemd when missing so the rest of
#   the script works reliably.
#
#   Two states to track:
#     SYSTEMD_AVAILABLE — systemctl binary exists (commands can be issued)
#     SYSTEMD_RUNNING    — systemd is actually PID 1 (commands will succeed)
#   When installed mid-session systemd is NOT PID 1 yet, so systemctl calls
#   won't take effect until reboot. Fallbacks handle that case.
SYSTEMD_AVAILABLE=false
SYSTEMD_RUNNING=false
command -v systemctl >/dev/null 2>&1 && SYSTEMD_AVAILABLE=true
[ "$(cat /proc/1/comm 2>/dev/null)" = "systemd" ] && SYSTEMD_RUNNING=true

if ! $SYSTEMD_AVAILABLE; then
    echo "systemd not found — installing..."
    if command -v apt >/dev/null 2>&1; then
        apt-get update -qq 2>/dev/null || true
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq systemd systemd-sysv dbus 2>/dev/null || true
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y -q systemd systemd-container 2>/dev/null || true
    elif command -v yum >/dev/null 2>&1; then
        yum install -y -q systemd 2>/dev/null || true
    fi
    # Re-check after install
    command -v systemctl >/dev/null 2>&1 && SYSTEMD_AVAILABLE=true
fi

if $SYSTEMD_AVAILABLE; then
    if $SYSTEMD_RUNNING; then
        log_info "systemd is available and running as PID 1"
    else
        log_warn "systemd installed but NOT running as PID 1 (current init: $(cat /proc/1/comm 2>/dev/null | head -1))."
        log_warn "systemctl commands won't take effect until after reboot. Using fallbacks."
    fi
else
    log_warn "systemd could not be installed. Using fallback methods for all operations."
fi

# 1d. Reject container environments (setup.sh:61-87)
#   Uses systemd-detect-virt when available; falls back to /proc-based
#   detection so the check works even without systemd as PID 1.
detect_container() {
    # Method 1: systemd-detect-virt (most reliable)
    if command -v systemd-detect-virt >/dev/null 2>&1; then
        local virt
        virt="$(systemd-detect-virt 2>/dev/null)"
        case "$virt" in
            openvz|lxc|lxc-libvirt|docker|podman|container|wsl|systemd-nspawn)
                echo "$virt"; return 0 ;;
        esac
    fi
    # Method 2: /.dockerenv file (Docker)
    [ -f /.dockerenv ] && { echo "docker"; return 0; }
    # Method 3: /proc/1/cgroup — containers appear in cgroup paths
    if grep -qaE '(docker|containerd|kubepods|lxc|openvz)' /proc/1/cgroup 2>/dev/null; then
        grep -qoE '(docker|containerd|kubepods|lxc|openvz)' /proc/1/cgroup 2>/dev/null | head -1
        return 0
    fi
    # Method 4: /proc/1/environ — LXC/OpenVZ set container= env var
    if grep -qa 'container=' /proc/1/environ 2>/dev/null; then
        echo "lxc"; return 0
    fi
    # Method 5: /proc/self/status CapEff — containers often lack CAP_SYS_ADMIN
    # (not reliable enough alone, skip)
    # Not a container
    return 1
}

CONTAINER_TYPE=""
if CONTAINER_TYPE="$(detect_container)"; then
    case "$CONTAINER_TYPE" in
        openvz)         die "OpenVZ is not supported!" ;;
        lxc|lxc-libvirt) die "Linux container is not supported!" ;;
        docker|podman)  die "Running in Docker/Podman container. WinBoxes requires a real OS or VM." ;;
        wsl)            die "Running in WSL. WinBoxes requires a real OS or VM." ;;
        systemd-nspawn) die "Running in systemd-nspawn container. WinBoxes requires a real OS or VM." ;;
        *)              die "Running in container ($CONTAINER_TYPE). WinBoxes requires a real OS or VM." ;;
    esac
fi

# 1e. OS must be Debian/Ubuntu (Go client: "OS is not supported. TinyInstaller
#     works on Debian and Ubuntu only")
if [ -f /etc/os-release ]; then
    . /etc/os-release
    case "$ID" in
        debian|ubuntu) : ;;
        *) die "$(red 'OS is not supported.') WinBoxes works on Debian and Ubuntu only." ;;
    esac
fi

# 1f. Refuse live-boot / rescue mode (Go client string)
if ls /run/live/medium >/dev/null 2>&1 || grep -qw "boot=live" /proc/cmdline 2>/dev/null \
   || grep -qE '(rescue|live|inst\.stage2)' /proc/cmdline 2>/dev/null; then
    die "WinBoxes cannot run on live boot or rescue mode. Please boot into normal mode!"
fi

# 1g. Firewall disable (setup.sh:147-157)
#   Uses systemctl when systemd is PID 1; falls back to `service` and
#   raw iptables otherwise so the step works on non-systemd hosts too.
if $SYSTEMD_RUNNING; then
    systemctl stop ufw 2>/dev/null || true
    systemctl stop firewalld 2>/dev/null || true
else
    # Fallback: service command (works with sysvinit, OpenRC, etc.)
    service ufw stop 2>/dev/null || true
    service firewalld stop 2>/dev/null || true
fi
if command -v iptables > /dev/null; then
    iptables -P INPUT ACCEPT; iptables -P FORWARD ACCEPT; iptables -P OUTPUT ACCEPT
    iptables -t nat -F; iptables -t mangle -F; iptables -F; iptables -X
fi

clear
echo "$(bold "$TOOL_NAME") $(green "$VERSION")"
echo

# ===========================================================================
#  STEP 2 — "Checking system information..."  (Go client UI string)
# ===========================================================================
echo "$(yellow 'Checking system information...')"

CPU_ARCH="$(uname -m)"
if [ -d /sys/firmware/efi ]; then SYSTEM_IS_UEFI="yes"; FIRMWARE_MODE="UEFI"; else SYSTEM_IS_UEFI="no"; FIRMWARE_MODE="BIOS"; fi
echo "  Architecture : $CPU_ARCH"
echo "  Firmware    : $FIRMWARE_MODE"

# Cloud provider hint — mirrors Go client's dmi-based detection
DMI_VENDOR=""
[ -r /sys/class/dmi/id/sys_vendor ] && DMI_VENDOR="$(cat /sys/class/dmi/id/sys_vendor 2>/dev/null)"
case "$DMI_VENDOR" in
    *Alibaba*|*alibaba*|*Aliyun*)   PROVIDER="alibaba cloud" ;;
    *Tencent*|*tencent*)            PROVIDER="tencent cloud" ;;
    *Huawei*|*HUAWEI*|*huawei*)     PROVIDER="huawei cloud" ;;
    *Oracle*|*oracle*)              PROVIDER="oracle cloud" ;;
    *Microsoft*|*Hyper-V*|*hyper-v*) PROVIDER="hyperv" ;;
    *VMware*|*VMW*)                 PROVIDER="vmware" ;;
    *Amazon*|*amazon*|*Xen*)        PROVIDER="aws" ;;
    *Google*|*google*)              PROVIDER="gcp" ;;
    *)                              PROVIDER="${DMI_VENDOR:-unknown}" ;;
esac
echo "  Provider    : $PROVIDER"

# IP configuration sanity — mirrors "Could not get ip configuration, this
# provider may not be supported by TinyInstaller."
if ! ip -4 addr show 2>/dev/null | grep -q "inet "; then
    die "$(red 'Could not get ip configuration, this provider may not be supported by WinBoxes.')"
fi
# Save primary NIC + IPv4 for the post-deploy summary
PRIMARY_IFACE="$(ip -4 -o route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1); exit}')"
[ -z "$PRIMARY_IFACE" ] && PRIMARY_IFACE="$(ip -4 -o addr show 2>/dev/null | awk '$2!="lo"{print $2; exit}')"
PRIMARY_IPV4="$(ip -4 addr show "$PRIMARY_IFACE" 2>/dev/null | awk '/inet /{print $2}' | cut -d/ -f1 | head -1)"
DEFAULT_GW="$(ip -4 -o route show default 2>/dev/null | awk '{print $3}' | head -1)"
echo "  Primary NIC : ${PRIMARY_IFACE:-unknown}"
echo "  IPv4        : ${PRIMARY_IPV4:-none}"
echo "  Gateway     : ${DEFAULT_GW:-unknown}"
echo

# ===========================================================================
#  STEP 3 — OS image menu
#     In the original Go client the profile list is fetched from the SAAS
#     server ("Please select a profile."). Here it is a static table — the
#     ONLY block that differs from the original. Each entry carries:
#     WIN_NAME  WIN_URL  USE_UEFI  (the same three fields the task asks for).
# ===========================================================================
WIN_NAME[1]="Windows Server 2012 R2"; WIN_URL[1]="https://archive.org/download/tamnguyen-2012r2/2012.img"; USE_UEFI[1]="no"
WIN_NAME[2]="Windows Server 2022";    WIN_URL[2]="https://archive.org/download/tamnguyen-2022/2022.img";   USE_UEFI[2]="no"
WIN_NAME[3]="Windows 11 LTSB";       WIN_URL[3]="https://archive.org/download/win_20260203/win.img";     USE_UEFI[3]="yes"
WIN_NAME[4]="Windows 10 LTSB 2015";  WIN_URL[4]="https://archive.org/download/win_20260208/win.img";     USE_UEFI[4]="no"
WIN_NAME[5]="Windows 10 LTSC 2023";  WIN_URL[5]="https://archive.org/download/win_20260215/win.img";     USE_UEFI[5]="no"
WIN_NAME[6]="Windows 10 LTSB 2022";  WIN_URL[6]="https://archive.org/download/win_20260717/win.img";     USE_UEFI[6]="no"

echo "Please select an image."
echo
for i in 1 2 3 4 5 6; do
    printf '  %s) %-26s  [UEFI=%-3s]\n' "$i" "${WIN_NAME[$i]}" "${USE_UEFI[$i]}"
done
echo "  *) default -> 1"
echo

if [ -n "$IMAGE_CHOICE" ]; then
    case "$IMAGE_CHOICE" in
        1|2|3|4|5|6) CHOICE="$IMAGE_CHOICE" ;;
        *) die "Invalid --image choice. Use 1..6" ;;
    esac
else
    while :; do
        read -r -p "$(bold 'Enter your choice [1-6]: ')" CHOICE
        [ -z "$CHOICE" ] && CHOICE=1
        case "$CHOICE" in
            1|2|3|4|5|6) break ;;
            *) echo "$(red 'Invalid input.') Please enter a valid number." ;;
        esac
    done
fi

SELECTED_NAME="${WIN_NAME[$CHOICE]}"
SELECTED_URL="${WIN_URL[$CHOICE]}"
SELECTED_UEFI="${USE_UEFI[$CHOICE]}"

echo
echo "You selected: $(cyan "$SELECTED_NAME")"
echo "  Image URL  : $SELECTED_URL"
echo "  Requires   : $([ "$SELECTED_UEFI" = yes ] && echo UEFI || echo BIOS)"
echo

# ===========================================================================
#  STEP 4 — disk selection  (mirrors Go client disk flow)
#     Go strings:
#       "Could not auto select disk. Please select the disk you want to
#        install. Available disks:"
#       "No disk found. Please specify the disk ... --disk /dev/sda"
#       "Install on raid device is not supported."
# ===========================================================================
scan_disks() {
    lsblk -nd -o NAME,SIZE,TYPE,MODEL,RO 2>/dev/null | while read -r name size type model ro; do
        [ "$type" != "disk" ] && continue
        case "$name" in loop*|ram*|sr*|zd*) continue ;; esac
        [ "$ro" = "1" ] && continue
        local dev="/dev/$name"
        if blkid "$dev" 2>/dev/null | grep -q "linux_raid_member"; then continue; fi
        local size_bytes
        size_bytes=$(blockdev --getsize64 "$dev" 2>/dev/null) || size_bytes=0
        [ "$size_bytes" = "0" ] && size_bytes=$(($(cat "/sys/block/$name/size" 2>/dev/null || echo 0) * 512))
        echo "$dev|$size|$model|$size_bytes"
    done
}

auto_select_largest_disk() {
    local largest_dev="" largest_bytes=0
    while IFS='|' read -r dev size model size_bytes; do
        if [ "$size_bytes" -gt "$largest_bytes" ]; then
            largest_bytes="$size_bytes"; largest_dev="$dev"
        fi
    done < <(scan_disks)
    [ -z "$largest_dev" ] && die "No writable disk found."
    echo "$largest_dev"
}

DISKS="$(scan_disks)"
[ -z "$DISKS" ] && die "No disk found. Please specify the disk you want to deploy by option --disk your_disk. e.g. sh $0 --disk /dev/sda"

declare -a DISK_ARRAY
echo "  #   DEVICE          SIZE        MODEL"
echo "  --- -------------- ----------- ----------------------------------"
i=1
while IFS='|' read -r dev size model size_bytes; do
    DISK_ARRAY+=("$dev")
    printf "  %-3d %-14s %-11s %s\n" "$i" "$dev" "$size" "${model:-unknown}"
    i=$((i+1))
done <<< "$DISKS"
echo

if [ -n "$TARGET_DISK" ]; then
    case "$TARGET_DISK" in /dev/*) : ;; *) TARGET_DISK="/dev/$TARGET_DISK" ;; esac
    [ ! -b "$TARGET_DISK" ] && die "Disk '$TARGET_DISK' is not a valid block device."
    if echo "$TARGET_DISK" | grep -qE '/dev/(md|dm-)'; then
        die "Install on raid device is not supported. Please select disk manually by specify option --disk your_disk."
    fi
    log_info "Using specified disk: $TARGET_DISK"
else
    TARGET_DISK="$(auto_select_largest_disk)"
    log_info "Auto-selected largest disk: $TARGET_DISK (use --disk /dev/XXX to override)"
fi

if blkid "$TARGET_DISK" 2>/dev/null | grep -qi "linux_raid_member"; then
    die "Disk '$TARGET_DISK' is part of a RAID array. RAID is not supported."
fi
log_success "Target disk: $TARGET_DISK"

DISK_SIZE_BYTES="$(blockdev --getsize64 "$TARGET_DISK" 2>/dev/null || echo 0)"
[ "$DISK_SIZE_BYTES" = "0" ] && DISK_SIZE_BYTES=$(($(cat "/sys/block/$(basename "$TARGET_DISK")/size" 2>/dev/null || echo 0) * 512))
DISK_SIZE_GB=$((DISK_SIZE_BYTES / 1024 / 1024 / 1024))
log_info "Disk size: ${DISK_SIZE_GB} GB"

# ===========================================================================
#  STEP 5 — firmware consistency check  (mirrors Go client's
#           "Attempt to convert MBR disks to GPT on UEFI systems" path)
# ===========================================================================
echo
if [ "$SELECTED_UEFI" = "yes" ] && [ "$SYSTEM_IS_UEFI" != "yes" ]; then
    die "$(red 'Error:') the selected image requires UEFI boot but this system is running in BIOS mode. Boot the VPS in UEFI mode and re-run, or pick a BIOS (USE_UEFI=no) image."
fi
if [ "$SELECTED_UEFI" = "no" ] && [ "$SYSTEM_IS_UEFI" = "yes" ]; then
    log_warn "Selected image is BIOS/MBR but system firmware is UEFI."
    log_warn "Stage-2 will attempt to convert MBR disks to GPT on UEFI systems (TinyInstaller behavior)."
    log_warn "If boot fails, enable CSM/Legacy mode in firmware."
fi

echo
echo "Profile: $(cyan "$SELECTED_NAME")"
echo "Disk   : $(cyan "$TARGET_DISK") ($DISK_SIZE_GB GB)"
echo "Mode   : $([ "$SELECTED_UEFI" = yes ] && echo UEFI || echo BIOS)"
echo

# ===========================================================================
#  STEP 6 — final confirmation  (Go client: "Are you sure you want to deploy
#           on this disk?")
# ===========================================================================
echo "$(yellow 'WinBoxes will write the image to your disk. ALL DATA WILL BE LOST.')"
read -r -p "Are you sure you want to deploy on this disk? [y/N] " CONFIRM
case "$CONFIRM" in
    y|Y|yes|YES) : ;;
    *) echo "Aborted."; exit 1 ;;
esac
echo

if $DRY_RUN; then
    log_info "[DRY RUN] Stopping before download/write. No changes made."
    exit 0
fi

# ===========================================================================
#  STEP 7 — download the image  (mirrors setup.sh downloadInstaller():
#           wget -> curl fallback; gzip-aware; base64 URL-decode parity kept)
# ===========================================================================
log_info "Downloading $SELECTED_NAME ..."

# base64 URL-decode parity (original downloadInstaller behaviour)
DOWNLOAD_URL="$SELECTED_URL"
case "$DOWNLOAD_URL" in
    http://*|https://*) : ;;
    *)
        decoded="$(printf '%s' "$DOWNLOAD_URL" | base64 -d 2>/dev/null)"
        case "$decoded" in http://*|https://*) DOWNLOAD_URL="$decoded" ;; esac
        ;;
esac

# Free-space check (fail fast instead of mid-transfer ENOSPC)
DATA_FREE_MB="$(df -m "$STAGE2_DIR" 2>/dev/null | awk 'NR==2{print $4}')"
REMOTE_SIZE_BYTES="$(curl -sIL "$DOWNLOAD_URL" 2>/dev/null | tr -d '\r' | awk -F': ' 'tolower($1)=="content-length"{print $2}' | tail -1)"
if [ -n "$REMOTE_SIZE_BYTES" ] && [ "$REMOTE_SIZE_BYTES" -gt 0 ] 2>/dev/null; then
    REMOTE_SIZE_MB=$((REMOTE_SIZE_BYTES / 1024 / 1024))
    REQUIRED_MB=$((REMOTE_SIZE_MB + REMOTE_SIZE_MB / 10))
    log_info "Remote image size: ${REMOTE_SIZE_MB} MB (need ~${REQUIRED_MB} MB free with margin)"
    if [ "${DATA_FREE_MB:-0}" -lt "$REQUIRED_MB" ]; then
        die "Not enough space in ${STAGE2_DIR}: have ${DATA_FREE_MB} MB, need ~${REQUIRED_MB} MB."
    fi
else
    log_warn "Could not determine remote size ahead of time. Proceeding (may fail mid-transfer)."
fi

download_image() {
    local url="$1" dest="$2"
    # Method 1: aria2c (fastest, multi-connection) — install if absent
    if ! command -v aria2c >/dev/null 2>&1; then
        log_info "Installing aria2 for high-speed download..."
        apt-get install -y -qq aria2 2>/dev/null || true
    fi
    if command -v aria2c >/dev/null 2>&1; then
        log_info "Using aria2c (16 connections)..."
        aria2c -x 16 -s 16 -c --max-connection-per-server=16 --min-split-size=1M \
            --console-log-level=notice --summary-interval=5 \
            -d "$(dirname "$dest")" -o "$(basename "$dest")" "$url" 2>&1 | tee -a "$LOGFILE" && return 0
        log_warn "aria2c failed, trying wget..."
    fi
    # Method 2: wget (IPv4, no-cert-check — same flags as setup.sh:111)
    if wget --no-check-certificate -4 -c --progress=bar:force:noscroll -O "$dest" "$url" 2>&1 | tee -a "$LOGFILE"; then
        return 0
    fi
    # Method 3: curl fallback (setup.sh:112)
    if curl -L -C - --progress-bar -o "$dest" "$url" 2>&1 | tee -a "$LOGFILE"; then
        return 0
    fi
    return 1
}

rm -f "$STAGE2_IMAGE" "$STAGE2_IMAGE_CHECKSUM" "$STAGE2_IMAGE_SIZE"
if ! download_image "$DOWNLOAD_URL" "$STAGE2_IMAGE"; then
    die "$(red 'Cannot download installer!')"
fi

DOWNLOADED_SIZE="$(stat -c%s "$STAGE2_IMAGE" 2>/dev/null || echo 0)"
[ "$DOWNLOADED_SIZE" -lt 10485760 ] && die "Downloaded image too small ($((DOWNLOADED_SIZE/1048576)) MB). Download likely failed."

echo "$DOWNLOADED_SIZE" > "$STAGE2_IMAGE_SIZE"

# archive.org serves raw .img — if it's actually gzip, decompress
if gunzip -t "$STAGE2_IMAGE" 2>/dev/null; then
    log_info "Image is gzip-compressed; decompressing..."
    gunzip -f "$STAGE2_IMAGE" || die "Cannot extract installer!"
    DOWNLOADED_SIZE="$(stat -c%s "$STAGE2_IMAGE")"
    echo "$DOWNLOADED_SIZE" > "$STAGE2_IMAGE_SIZE"
fi

# Checksum (original relies on server-side; here we compute for transparency)
log_info "Computing SHA256 checksum..."
CHK="$(sha256sum "$STAGE2_IMAGE" 2>/dev/null | awk '{print $1}')"
echo "$CHK  $STAGE2_IMAGE" > "$STAGE2_IMAGE_CHECKSUM"
log_info "SHA256: $CHK"

IMAGE_SIZE_MB=$((DOWNLOADED_SIZE / 1024 / 1024))
DISK_SIZE_MB=$((DISK_SIZE_BYTES / 1024 / 1024))
[ "$IMAGE_SIZE_MB" -gt "$DISK_SIZE_MB" ] && die "Image (${IMAGE_SIZE_MB} MB) > disk (${DISK_SIZE_MB} MB)!"
log_success "Image fits on disk (${IMAGE_SIZE_MB} MB < ${DISK_SIZE_MB} MB)"

# ===========================================================================
#  STEP 8 — prepare Stage-2 kernel & initramfs
#     Uses host kernel (which has virtio drivers for the VPS disk/NIC).
#     Builds a custom initramfs with busybox + an embedded init script that
#     dd's the image, fixes UEFI/BIOS boot, and reboots.
# ===========================================================================
log_info "Preparing Stage-2 kernel & initramfs..."

# 8a. Find host kernel
KERNEL_VER="$(uname -r)"
KERNEL_IMAGE=""
if [ -f "/boot/vmlinuz-$KERNEL_VER" ]; then KERNEL_IMAGE="/boot/vmlinuz-$KERNEL_VER"
elif [ -f "/vmlinuz" ]; then KERNEL_IMAGE="/vmlinuz"
elif ls /boot/vmlinuz-* >/dev/null 2>&1; then KERNEL_IMAGE="$(ls -t /boot/vmlinuz-* 2>/dev/null | head -1)"
else die "Could not find kernel image in /boot/"; fi
log_info "Host kernel: $KERNEL_VER"
cp "$KERNEL_IMAGE" "$STAGE2_KERNEL"

# 8b. Check virtio support (required for VPS disks/NICs in initramfs)
has_virtio=false
if [ -d "/lib/modules/$KERNEL_VER/kernel/drivers/virtio" ]; then has_virtio=true
elif find "/lib/modules/$KERNEL_VER" -name "virtio_blk.ko*" -o -name "virtio_net.ko*" 2>/dev/null | grep -q virtio; then has_virtio=true; fi
if ! $has_virtio; then
    log_warn "Host kernel lacks virtio drivers — auto-downloading generic Debian kernel..."
    pkg_index="/tmp/debian-kernel-packages.gz"
    wget -qO "$pkg_index" "https://deb.debian.org/debian/dists/stable/main/binary-amd64/Packages.gz" 2>/dev/null || true
    auto_kernel_version=""
    if [ -f "$pkg_index" ]; then
        auto_kernel_version="$(zcat "$pkg_index" 2>/dev/null | awk '/^Package: linux-image-6\./{pkg=$2} /^Version:/ && pkg {ver=$2; gsub(/^.*linux-image-/,"",pkg); if(!seen[ver]){print ver; seen[ver]=1}}' | sort -V | tail -1)"
        rm -f "$pkg_index"
    fi
    [ -z "$auto_kernel_version" ] && auto_kernel_version="6.1.0-28-amd64"
    auto_kernel_url="https://deb.debian.org/debian/pool/main/l/linux-signed-amd64/linux-image-${auto_kernel_version}_${auto_kernel_version#*-}_amd64.deb"
    log_info "Downloading generic kernel $auto_kernel_version..."
    deb_file="/tmp/winboxes-kernel.deb"; rm -f "$deb_file"
    if wget --no-check-certificate -4 -q --show-progress -O "$deb_file" "$auto_kernel_url" 2>&1 | tee -a "$LOGFILE"; then
        extract_dir="/tmp/winboxes-kernel-extract"; rm -rf "$extract_dir"; mkdir -p "$extract_dir"
        dpkg-deb -x "$deb_file" "$extract_dir" 2>/dev/null || { ar x "$deb_file" --output="$extract_dir" 2>/dev/null || true; tar -xf "$extract_dir/data.tar.xz" -C "$extract_dir" 2>/dev/null || true; }
        kernel_found="$(find "$extract_dir/boot" -name 'vmlinuz-*' 2>/dev/null | head -1)"
        if [ -n "$kernel_found" ]; then
            cp "$kernel_found" "$STAGE2_KERNEL"
            mkdir -p /lib/modules/; cp -r "$extract_dir/lib/modules/"* /lib/modules/ 2>/dev/null || true
            log_success "Generic kernel installed"
        fi
        rm -rf "$extract_dir" "$deb_file"
    else
        log_warn "Failed to download generic kernel — using host kernel anyway (may lack virtio)"
    fi
fi
log_info "Kernel ready at $STAGE2_KERNEL"

# 8c. Build Stage-2 initramfs with embedded init script
build_stage2_initramfs() {
    local tmpdir; tmpdir="$(mktemp -d /tmp/winboxes-initramfs.XXXXXX)"
    log_info "Building Stage-2 initramfs in $tmpdir..."
    mkdir -p "$tmpdir"/{bin,dev,etc,lib,lib64,mnt,mnt2,proc,root,run,sbin,sys,tmp,usr/{bin,sbin,lib,lib64,share}}

    # -----------------------------------------------------------------------
    # Find STATIC busybox (REQUIRED).
    #
    # A dynamic busybox needs its ELF interpreter (e.g.
    # /lib64/ld-linux-x86-64.so.2) at the exact same path inside the
    # initramfs. If the interpreter is missing, the kernel cannot exec
    # /init (whose shebang is #!/bin/busybox sh), tries all fallback inits
    # (/sbin/init, /bin/sh …) which also fail, then PANICS with:
    #     "No working init found. Try passing init= option to kernel."
    #
    # ROOT CAUSE of the panic on winhost: the old detection used
    #     file "$c" | grep "statically linked"
    # but `file` is NOT installed on many minimal VPS images. When `file`
    # is absent the grep gets empty input → static busybox is never
    # detected → script falls to the "dynamic fragile" path → bundles
    # some libs but MISSES the ELF interpreter → exec fails → panic.
    #
    # FIX: use `ldd` instead — it is part of libc-bin and present on
    # EVERY Linux system. `ldd <static-binary>` prints
    # "not a dynamic executable". Also verify the binary actually runs.
    # -----------------------------------------------------------------------

    # Force-install busybox-static so a static binary is available.
    apt-get install -y -qq busybox-static 2>/dev/null || true

    is_static_elf() {
        # ldd is always present (libc-bin). Returns 0 (true) if static.
        ldd "$1" 2>&1 | grep -q "not a dynamic executable"
    }

    find_static_busybox() {
        local candidates=(
            "/usr/lib/initramfs-tools/bin/busybox"
            "/bin/busybox.static" "/sbin/busybox.static"
            "/usr/bin/busybox.static" "/usr/bin/busybox"
            "/bin/busybox" "/usr/lib/busybox-static/bin/busybox"
        )
        command -v busybox >/dev/null 2>&1 && candidates=("$(command -v busybox)" "${candidates[@]}")
        for c in "${candidates[@]}"; do
            if [ -x "$c" ] && is_static_elf "$c"; then echo "$c"; return 0; fi
        done
        return 1
    }

    BUSYBOX_BIN=""
    if BUSYBOX_BIN="$(find_static_busybox)"; then
        log_info "Using static busybox: $BUSYBOX_BIN (verified via ldd)"
    else
        log_warn "No static busybox found after install — trying dynamic with full lib bundle..."
        # Last resort: dynamic busybox. We MUST get its interpreter + all libs.
        if command -v busybox >/dev/null 2>&1; then
            BUSYBOX_BIN="$(command -v busybox)"
        else
            die "Cannot find busybox (static or dynamic). Required for Stage-2 initramfs."
        fi
    fi

    # THE critical runtime check: prove busybox can actually execute.
    # If this fails, the initramfs would panic the kernel — fail NOW instead.
    if ! "$BUSYBOX_BIN" true 2>/dev/null; then
        die "FATAL: busybox at '$BUSYBOX_BIN' cannot execute. The initramfs /init would fail → kernel panic 'No working init found'. Install busybox-static and retry."
    fi
    log_success "busybox runtime verification passed (can exec)"

    cp -L "$BUSYBOX_BIN" "$tmpdir/bin/busybox"; chmod +x "$tmpdir/bin/busybox"
    # busybox applet symlinks
    for applet in sh ash cat cp dd echo ls mkdir mktemp mount umount sleep grep awk sed cut head tail tr wc printf test "[" "[[" chmod chown ln rm rmdir sync blockdev mdev reboot poweroff switch_root kill pidof df du stat basename dirname readlink expr seq fold getopt which losetup findfs efibootmgr sgdisk sfdisk mkfs.vfat mkfs.fat; do
        ln -sf busybox "$tmpdir/bin/$applet" 2>/dev/null || true
    done
    ln -sf busybox "$tmpdir/sbin/mdev" 2>/dev/null || true

    # -----------------------------------------------------------------------
    # Fallback init paths — the kernel's init search order is:
    #   /init → /sbin/init → /etc/init → /bin/init → /bin/sh
    # If /init's shebang exec fails (e.g. interpreter missing), the kernel
    # tries the next. By providing /sbin/init → /init and /bin/sh → busybox
    # (static), even if /init fails we drop to a shell instead of panicking.
    # -----------------------------------------------------------------------
    ln -sf /init "$tmpdir/sbin/init" 2>/dev/null || true
    ln -sf /init "$tmpdir/etc/init" 2>/dev/null || true
    ln -sf /init "$tmpdir/bin/init" 2>/dev/null || true
    # /bin/sh is already symlinked above, but ensure it exists as last resort

    # Write init FIRST, then set perms (avoids "Text file busy")
    cat > "$tmpdir/init" << 'STAGE2INIT'
#!/bin/busybox sh
# ==========================================================================
# WinBoxes Stage 2 — Initramfs Init Script
# ==========================================================================
# Runs after reboot inside our custom initramfs. Detects target disk, dd's
# the OS image, fixes UEFI/BIOS boot, reboots into Windows.
# ==========================================================================
export PATH=/bin:/sbin:/usr/bin:/usr/sbin

mount -t proc  proc  /proc
mount -t sysfs sysfs /sys
mount -t devtmpfs devtmpfs /dev
mount -t tmpfs  tmpfs /tmp
mount -t tmpfs  tmpfs /run
/sbin/mdev -s 2>/dev/null || true

LOG="/run/install.log"; :> "$LOG"
log_msg() {
    local ts; ts=$(cut -d. -f1 /proc/uptime 2>/dev/null || echo 0)
    local msg="[${ts}s] $*"
    echo "$msg" | tee -a "$LOG"
    echo "$msg" > /dev/console 2>/dev/null || true
    echo "$msg" > /dev/ttyS0 2>/dev/null || true
    echo "$msg" > /dev/tty0 2>/dev/null || true
}

log_msg "=== WinBoxes Stage 2 Starting ==="

# Bring up network (for debugging via SSH/VNC if needed)
log_msg "=== BRINGING UP NETWORK ==="
for mod in virtio_net virtio_pci vmxnet3 hv_netvsc xen_netfront e1000 e1000e r8169 igb ixgbe; do
    modprobe "$mod" 2>/dev/null && log_msg "Loaded: $mod" || true
done
sleep 2
NIC_UP=false
for iface in $(ip link show 2>/dev/null | awk -F': ' '/^[0-9]+:/{print $2}' | grep -v lo); do
    ip link set up "$iface" 2>/dev/null || true
    if udhcpc -i "$iface" -n -q -t 3 2>/dev/null; then
        log_msg "DHCP OK on $iface"; NIC_UP=true; break
    fi
    dhclient -1 "$iface" 2>/dev/null && { log_msg "DHCP OK on $iface"; NIC_UP=true; break; } || true
done
$NIC_UP && log_msg "Network UP — use VNC/serial console to debug" || log_msg "WARNING: Network NOT configured"

# Parse kernel cmdline
CMDLINE="$(cat /proc/cmdline)"
log_msg "Kernel cmdline: $CMDLINE"
extract_param() {
    local name="$1" default="$2" value=""
    for word in $CMDLINE; do
        case "$word" in "${name}=*") value="${word#${name}=}"; break ;; esac
    done
    echo "${value:-$default}"
}

TARGET_DISK=$(extract_param "target_disk" "")
IMAGE_FILE=$(extract_param "image_file" "/winboxes-data/winboxes-disk.img")
IMAGE_CHECKSUM=$(extract_param "image_checksum" "")
DATA_FS_UUID=$(extract_param "data_fs_uuid" "")
SELECTED_UEFI=$(extract_param "selected_uefi" "no")

log_msg "Target disk: ${TARGET_DISK:-auto}"
log_msg "Image file:  $IMAGE_FILE"
log_msg "Checksum:    ${IMAGE_CHECKSUM:-none}"
log_msg "USE_UEFI:    $SELECTED_UEFI"

# Mount the partition holding the image (root fs, NOT /boot — tiny /boot pitfall)
mkdir -p /mnt/data /boot 2>/dev/null || true
MOUNTED_DATA=false; DATA_MNT=""

if [ -n "$DATA_FS_UUID" ]; then
    dev_by_uuid="$(blkid -U "$DATA_FS_UUID" 2>/dev/null || findfs "UUID=$DATA_FS_UUID" 2>/dev/null)"
    if [ -n "$dev_by_uuid" ] && mount "$dev_by_uuid" /mnt/data 2>/dev/null; then
        MOUNTED_DATA=true; DATA_MNT=/mnt/data
        log_msg "Mounted $dev_by_uuid (UUID=$DATA_FS_UUID) to /mnt/data"
    fi
fi
if ! $MOUNTED_DATA; then
    log_msg "UUID mount failed, falling back to device-name guessing..."
    for try in /dev/sda1 /dev/vda1 /dev/nvme0n1p1 /dev/xvda1; do
        if mount "$try" /boot 2>/dev/null; then MOUNTED_DATA=true; DATA_MNT=/boot; break; fi
    done
    if ! $MOUNTED_DATA; then
        for dev in /dev/sd[a-z][0-9] /dev/vd[a-z][0-9] /dev/nvme[0-9]n[0-9]p[0-9] /dev/xvd[a-z][0-9]; do
            mount -t ext4 "$dev" /boot 2>/dev/null && { MOUNTED_DATA=true; DATA_MNT=/boot; break; } || \
            mount -t xfs "$dev" /boot 2>/dev/null && { MOUNTED_DATA=true; DATA_MNT=/boot; break; } || true
        done
    fi
    $MOUNTED_DATA && log_msg "Mounted (fallback) to $DATA_MNT"
fi

# Verify image file exists
if [ -n "$DATA_MNT" ] && [ -f "${DATA_MNT}${IMAGE_FILE}" ]; then IMAGE_FILE="${DATA_MNT}${IMAGE_FILE}"; fi
if [ ! -f "$IMAGE_FILE" ]; then
    log_msg "ERROR: Image not at $IMAGE_FILE — searching fallbacks..."
    for candidate in "${DATA_MNT}/winboxes-data/winboxes-disk.img" "${DATA_MNT}/winboxes-disk.img" /boot/winboxes-data/winboxes-disk.img /boot/winboxes-disk.img /winboxes-data/winboxes-disk.img /winboxes-disk.img; do
        if [ -n "$candidate" ] && [ -f "$candidate" ]; then log_msg "Found at: $candidate"; IMAGE_FILE="$candidate"; break; fi
    done
    if [ ! -f "$IMAGE_FILE" ]; then
        log_msg "FATAL: No image found."; while true; do sleep 60; done
    fi
fi
IMAGE_SIZE=$(stat -c%s "$IMAGE_FILE" 2>/dev/null || echo 0)
log_msg "Image size: $IMAGE_SIZE bytes"

# Verify checksum
if [ -n "$IMAGE_CHECKSUM" ]; then
    log_msg "Verifying checksum..."
    COMPUTED=$(sha256sum "$IMAGE_FILE" 2>/dev/null | cut -d' ' -f1)
    if [ "$COMPUTED" != "$IMAGE_CHECKSUM" ]; then
        log_msg "CHECKSUM MISMATCH! Expected: $IMAGE_CHECKSUM Computed: $COMPUTED"
        log_msg "Aborting to prevent corruption."; while true; do sleep 60; done
    fi
    log_msg "Checksum verified OK"
fi

# Detect target disk
if [ -z "$TARGET_DISK" ]; then
    log_msg "Auto-detecting target disk..."
    for dev in /dev/sda /dev/vda /dev/nvme0n1 /dev/xvda; do
        if lsblk -ndo NAME "$dev" 2>/dev/null | grep -q "$(basename "$dev")"; then TARGET_DISK="$dev"; break; fi
    done
    [ -z "$TARGET_DISK" ] && TARGET_DISK="/dev/$(lsblk -ndo NAME -l 2>/dev/null | grep -vE '^(loop|sr|ram)' | head -1)"
    log_msg "Auto-detected: $TARGET_DISK"
fi
[ ! -b "$TARGET_DISK" ] && { log_msg "ERROR: $TARGET_DISK not a block device"; while true; do sleep 60; done; }

# Write image to disk
log_msg "=== WRITING IMAGE TO $TARGET_DISK ==="
umount ${TARGET_DISK}?* 2>/dev/null; umount ${TARGET_DISK} 2>/dev/null; sync
log_msg "dd if=$IMAGE_FILE of=$TARGET_DISK bs=4M conv=fsync status=progress"
dd if="$IMAGE_FILE" of="$TARGET_DISK" bs=4M conv=fsync status=progress 2>&1 | tee -a "$LOG"
sync
blockdev --flushbufs "$TARGET_DISK" 2>/dev/null || true
log_msg "=== IMAGE WRITTEN ==="

# Wait for partitions
sleep 3
blockdev --rereadpt "$TARGET_DISK" 2>/dev/null || true
udevadm settle 2>/dev/null || mdev -s 2>/dev/null || sleep 5

IS_UEFI=false
[ -d /sys/firmware/efi ] && IS_UEFI=true
$IS_UEFI && log_msg "Firmware: UEFI" || log_msg "Firmware: BIOS"

# Detect OS type + partitions
log_msg "=== DETECTING OS TYPE ==="
OS_TYPE="unknown"; ROOT_PART=""; EFI_PART=""
for pnum in 1 2 3 4 5; do
    for part_dev in "${TARGET_DISK}${pnum}" "${TARGET_DISK}p${pnum}"; do
        [ -b "$part_dev" ] || continue
        fstype=$(blkid -s TYPE -o value "$part_dev" 2>/dev/null || echo "")
        if [ "$fstype" = "vfat" ]; then EFI_PART="$part_dev"; log_msg "Found ESP: $EFI_PART"; continue; fi
        if [ -z "$ROOT_PART" ]; then
            for mt in ntfs ntfs3 ext4 xfs btrfs ext3 ext2; do
                if mount -t "$mt" -o ro "$part_dev" /mnt 2>/dev/null; then
                    ROOT_PART="$part_dev"; log_msg "Mounted $part_dev ($mt)"
                    if [ -f /mnt/Windows/System32/ntoskrnl.exe ] || [ -f /mnt/Windows/System32/winload.exe ] || [ -f /mnt/Windows/System32/winload.efi ]; then
                        OS_TYPE="windows"; log_msg "Detected: Windows"
                    elif [ -f /mnt/etc/os-release ] || [ -f /mnt/etc/debian_version ]; then
                        OS_TYPE="linux"; log_msg "Detected: Linux"
                    fi
                    umount /mnt 2>/dev/null || true
                    break 2
                fi
            done
        fi
    done
done
log_msg "OS: $OS_TYPE | Root: ${ROOT_PART:-none} | EFI: ${EFI_PART:-none}"

# Fix boot per OS type + firmware
log_msg "=== MOUNTING NEW OS ==="
if [ -z "$ROOT_PART" ]; then
    log_msg "WARNING: No root partition found. Image should boot from its own bootloader."
else
    mount -o rw "$ROOT_PART" /mnt 2>/dev/null || {
        for mt in ntfs ntfs3 ext4 xfs btrfs ext3 ext2; do
            mount -t "$mt" -o rw "$ROOT_PART" /mnt 2>/dev/null && break || true
        done
    }
    if mountpoint -q /mnt 2>/dev/null; then
        log_msg "Mounted new OS root at /mnt"

        if [ "$OS_TYPE" = "windows" ]; then
            log_msg "Windows OS detected"
            [ -f /mnt/Windows/System32/winload.efi ] && log_msg "winload.efi found"
            [ -f /mnt/Windows/Boot/EFI/bootmgfw.efi ] && log_msg "bootmgfw.efi found"

            if $IS_UEFI; then
                # UEFI: if disk is MBR, convert to GPT + create ESP (TinyInstaller: "Attempt
                # to convert MBR disks to GPT on UEFI systems")
                log_msg "UEFI mode — checking partition table..."
                pt_check=$(fdisk -l "$TARGET_DISK" 2>/dev/null | grep -i "disklabel type" | tr '[:upper:]' '[:lower:]')

                if echo "$pt_check" | grep -q "dos"; then
                    log_msg "Disk is MBR. Converting to GPT + creating ESP..."
                    last_part_end=$(fdisk -l "$TARGET_DISK" 2>/dev/null | grep "^${TARGET_DISK}" | awk 'END{print $3}')
                    [ -z "$last_part_end" ] && last_part_end=$(blockdev --getsz "$TARGET_DISK" 2>/dev/null)
                    total_sectors=$(blockdev --getsz "$TARGET_DISK" 2>/dev/null || echo 0)
                    efi_size_sectors=$((200 * 1024 * 1024 / 512))
                    efi_start=$((total_sectors - efi_size_sectors))

                    if [ "$efi_start" -gt "$last_part_end" ] && [ "$total_sectors" -gt 0 ] 2>/dev/null; then
                        log_msg "Creating ESP: start=$efi_start size=200MB"
                        command -v sgdisk >/dev/null 2>&1 && sgdisk -g "$TARGET_DISK" 2>&1 | tee -a "$LOG"
                        echo "${efi_start},${efi_size_sectors},ef00" | sfdisk -a "$TARGET_DISK" 2>&1 | tee -a "$LOG" || \
                            printf "n\n\n\n+200M\nt\n1\nw\n" | fdisk "$TARGET_DISK" 2>&1 | tee -a "$LOG" || true
                        blockdev --rereadpt "$TARGET_DISK" 2>/dev/null; sleep 2

                        efi_dev=""
                        for pdev in "${TARGET_DISK}3" "${TARGET_DISK}4" "${TARGET_DISK}5" "${TARGET_DISK}p3" "${TARGET_DISK}p4"; do
                            [ -b "$pdev" ] && { efi_dev="$pdev"; break; }
                        done
                        if [ -n "$efi_dev" ]; then
                            log_msg "EFI partition: $efi_dev"
                            mkfs.vfat -F 32 -n "EFI" "$efi_dev" 2>&1 | tee -a "$LOG" || mkfs.fat -F 32 "$efi_dev" 2>&1 | tee -a "$LOG"
                            mkdir -p /mnt2
                            if mount -t vfat "$efi_dev" /mnt2 2>/dev/null; then
                                mkdir -p /mnt2/EFI/BOOT /mnt2/EFI/Microsoft/Boot
                                [ -f /mnt/Windows/Boot/EFI/bootmgfw.efi ] && {
                                    cp /mnt/Windows/Boot/EFI/bootmgfw.efi /mnt2/EFI/Microsoft/Boot/ 2>/dev/null
                                    cp /mnt/Windows/Boot/EFI/bootmgfw.efi /mnt2/EFI/BOOT/BOOTX64.EFI 2>/dev/null
                                }
                                cp /mnt/Windows/Boot/EFI/* /mnt2/EFI/Microsoft/Boot/ 2>/dev/null || true
                                cp -r /mnt/Windows/Boot/Resources /mnt2/EFI/Microsoft/Boot/ 2>/dev/null || true
                                cp -r /mnt/Windows/Boot/DVD/EFI /mnt2/EFI/Microsoft/Boot/ 2>/dev/null || true
                                log_msg "ESP populated with Windows boot files"
                                umount /mnt2 2>/dev/null
                            fi
                        fi
                    else
                        log_msg "Cannot create ESP — trying efibootmgr"
                        command -v efibootmgr >/dev/null 2>&1 && \
                            efibootmgr --create --disk "$TARGET_DISK" --part 1 --label "Windows" 2>&1 | tee -a "$LOG" || true
                    fi
                else
                    log_msg "Disk already GPT — no conversion needed"
                    if [ -n "$EFI_PART" ]; then
                        mkdir -p /mnt2
                        if mount -t vfat "$EFI_PART" /mnt2 2>/dev/null; then
                            if [ ! -f /mnt2/EFI/Microsoft/Boot/bootmgfw.efi ]; then
                                mkdir -p /mnt2/EFI/BOOT /mnt2/EFI/Microsoft/Boot
                                [ -f /mnt/Windows/Boot/EFI/bootmgfw.efi ] && \
                                    cp /mnt/Windows/Boot/EFI/bootmgfw.efi /mnt2/EFI/BOOT/BOOTX64.EFI 2>/dev/null
                            fi
                            umount /mnt2 2>/dev/null
                        fi
                    fi
                fi
                # Register UEFI boot entry
                if command -v efibootmgr >/dev/null 2>&1; then
                    target_efi="${EFI_PART:-${efi_dev:-${TARGET_DISK}1}}"
                    efi_partnum=$(echo "$target_efi" | grep -oE '[0-9]+$')
                    efibootmgr --create --disk "$TARGET_DISK" --part "$efi_partnum" \
                        --label "Windows Boot Manager" --loader "\\EFI\\BOOT\\BOOTX64.EFI" 2>&1 | tee -a "$LOG" || true
                fi
            else
                # BIOS: verify MBR boot signature 55 AA
                log_msg "BIOS mode: verifying MBR boot signature..."
                mbr_sig=$(dd if="$TARGET_DISK" bs=1 skip=510 count=2 2>/dev/null | od -An -tx1 | tr -d ' ')
                if [ "$mbr_sig" = "55aa" ]; then
                    log_msg "MBR signature valid (55 AA) — should boot"
                else
                    log_msg "WARNING: MBR signature missing — writing 55 AA"
                    printf '\x55\xaa' | dd of="$TARGET_DISK" bs=1 seek=510 conv=notrunc 2>/dev/null
                fi
            fi

        elif [ "$OS_TYPE" = "linux" ]; then
            log_msg "Linux OS detected — regenerating initramfs + installing GRUB"
            mount -t proc proc /mnt/proc 2>/dev/null || true
            mount -t sysfs sysfs /mnt/sys 2>/dev/null || true
            mount -t devtmpfs devtmpfs /mnt/dev 2>/dev/null || true
            chroot /mnt update-initramfs -c -k all 2>/dev/null || chroot /mnt dracut --regenerate-all --no-hostonly 2>/dev/null || \
                log_msg "WARNING: Could not regenerate initramfs"
            if $IS_UEFI; then
                [ -n "$EFI_PART" ] && { mkdir -p /mnt/boot/efi; mount "$EFI_PART" /mnt/boot/efi 2>/dev/null || true; }
                chroot /mnt grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=GRUB --removable 2>&1 | tee -a "$LOG" || \
                chroot /mnt grub2-install --target=x86_64-efi --efi-directory=/boot/efi --removable 2>&1 | tee -a "$LOG" || \
                    log_msg "WARNING: grub-install (UEFI) failed"
                umount /mnt/boot/efi 2>/dev/null || true
            else
                chroot /mnt grub-install --target=i386-pc "$TARGET_DISK" 2>&1 | tee -a "$LOG" || \
                chroot /mnt grub2-install --target=i386-pc "$TARGET_DISK" 2>&1 | tee -a "$LOG" || \
                    log_msg "WARNING: grub-install (BIOS) failed"
            fi
            chroot /mnt update-grub 2>/dev/null || chroot /mnt grub-mkconfig -o /boot/grub/grub.cfg 2>/dev/null || true
            umount /mnt/proc /mnt/sys /mnt/dev 2>/dev/null || true
        fi
        umount /mnt 2>/dev/null || true
    else
        log_msg "WARNING: Could not mount root partition. Image should boot from its own bootloader."
    fi
fi

# Reboot into new OS
log_msg "=== REBOOTING INTO NEW OS ==="
log_msg "Install log saved. System will reboot in 5 seconds..."
sync
sleep 5
reboot -f 2>/dev/null || reboot 2>/dev/null || echo b > /proc/sysrq-trigger 2>/dev/null || true
log_msg "Reboot sent. If stuck, manually reboot."
while true; do sleep 60; done
STAGE2INIT

    chmod +x "$tmpdir/init"

    # Copy essential tools into initramfs
    for tool in dd lsblk blkid findfs mount umount chroot sync blockdev sha256sum fdisk sfdisk efibootmgr sgdisk mkfs.vfat mkfs.fat gunzip; do
        command -v "$tool" >/dev/null 2>&1 && cp "$(command -v "$tool")" "$tmpdir/bin/" 2>/dev/null || true
    done

    # Copy shared libs + ELF interpreter for the dynamic tools we added.
    # The ELF interpreter (e.g. /lib64/ld-linux-x86-64.so.2) is REQUIRED for
    # any dynamic binary to run — missing it is the #1 cause of
    # "No working init found" panics with custom initramfs.
    if command -v ldd >/dev/null 2>&1; then
        scan_bins=()
        for b in dd lsblk blkid findfs mount umount chroot blockdev sha256sum fdisk sfdisk efibootmgr sgdisk mkfs.vfat mkfs.fat gunzip busybox; do
            [ -x "$tmpdir/bin/$b" ] && scan_bins+=("$tmpdir/bin/$b")
        done
        [ ${#scan_bins[@]} -gt 0 ] && {
            libs=$(ldd "${scan_bins[@]}" 2>/dev/null | awk '/=>/ {print $3}' | sort -u || true)
            interp=$(ldd "${scan_bins[@]}" 2>/dev/null | awk '!/=>/ && /^[[:space:]]*\// {print $1}' | sort -u || true)
            libs="$libs $interp"
        }
        # ALSO: extract interpreter directly via readelf — most reliable,
        # works even if ldd output format differs.
        if command -v readelf >/dev/null 2>&1; then
            for b in "${scan_bins[@]}"; do
                interp_re=$(readelf -l "$b" 2>/dev/null | awk '/interpreter:/ {gsub(/\[|\]/,"",$NF); print $NF}')
                libs="$libs $interp_re"
            done
        fi
        libs="$libs $(ldconfig -p 2>/dev/null | awk 'NR>1{print $NF}' | grep -E '(libc\.so|libz\.so|liblzma\.so|liblz4\.so|libpthread|libntfs|libuuid|libblkid)' | sort -u || true)"
        for lib in $libs; do
            if [ -f "$lib" ]; then
                mkdir -p "$tmpdir/$(dirname "$lib")"
                cp -L "$lib" "$tmpdir/$lib" 2>/dev/null || true
            fi
        done
    fi
    # Ensure standard lib dirs (Debian + EL layouts)
    for lib_dir in /lib/x86_64-linux-gnu /lib64 /usr/lib/x86_64-linux-gnu /usr/lib64; do
        if [ -d "$lib_dir" ]; then
            mkdir -p "$tmpdir/$lib_dir"
            for pat in libc.so* libz.so* liblzma.so* liblz4.so* libpthread* libdl.so* libm.so* libntfs* libuuid* libblkid*; do
                cp -L "$lib_dir"/$pat "$tmpdir/$lib_dir/" 2>/dev/null || true
            done
        fi
    done

    # Build cpio archive
    log_info "Building cpio archive..."
    ( cd "$tmpdir" && find . -print0 | cpio --null --create --format=newc 2>/dev/null | gzip > "$STAGE2_INITRD" )
    [ -f "$STAGE2_INITRD" ] || die "Failed to build Stage-2 initramfs"

    # CRITICAL: verify the cpio archive actually contains /init and /bin/busybox.
    # An empty or corrupt archive (e.g. cpio not installed, find produced
    # nothing) would cause the kernel to unpack an empty rootfs and panic
    # with "No working init found".
    CPIO_LIST="$(zcat "$STAGE2_INITRD" 2>/dev/null | cpio -t 2>/dev/null)"
    if ! echo "$CPIO_LIST" | grep -qE '^(\./)?init$'; then
        die "FATAL: initramfs archive does not contain /init. The kernel would panic 'No working init found'. Check that cpio is installed and the build directory is populated."
    fi
    if ! echo "$CPIO_LIST" | grep -qE '^(\./)?bin/busybox$'; then
        die "FATAL: initramfs archive does not contain /bin/busybox. Kernel cannot exec /init shebang."
    fi
    log_success "initramfs archive verified: /init and /bin/busybox present"
    log_success "Stage-2 initramfs built: $STAGE2_INITRD ($(($(stat -c%s "$STAGE2_INITRD")/1024)) KB)"
    rm -rf "$tmpdir"
}

build_stage2_initramfs

# ===========================================================================
#  STEP 9 — write GRUB menuentry + grub-reboot
#     (mirrors TinyInstaller's "menuentry TinyInstaller" + grub-reboot)
# ===========================================================================
log_info "Configuring GRUB..."

find_grub_cfg() {
    if [ "$FIRMWARE_MODE" = "UEFI" ]; then
        for path in /boot/efi/EFI/*/grub.cfg /boot/grub/grub.cfg /boot/grub2/grub.cfg; do
            [ -f "$path" ] && { echo "$path"; return; }
        done
    else
        for path in /boot/grub2/grub.cfg /boot/grub/grub.cfg; do
            [ -f "$path" ] && { echo "$path"; return; }
        done
    fi
    echo ""
}
GRUB_CFG="$(find_grub_cfg)"
[ -z "$GRUB_CFG" ] && die "Could not find grub.cfg. Check your GRUB installation."
log_info "GRUB config: $GRUB_CFG"

cp "$GRUB_CFG" "${GRUB_CFG}.winboxes.bak"
log_info "Backed up GRUB config to ${GRUB_CFG}.winboxes.bak"

remove_existing_entry() { sed -i '/^### BEGIN WINBOXES ###/,/^### END WINBOXES ###/d' "$1"; }

checksum="$(cut -d' ' -f1 "$STAGE2_IMAGE_CHECKSUM" 2>/dev/null || echo "")"

# Find the partition holding STAGE2_DIR for GRUB search directive
search_directive="search --no-floppy --file --set=root /${STAGE2_GRUB_REL}/winboxes-disk.img"
data_uuid=""; data_dev=""
if command -v findmnt >/dev/null 2>&1; then
    data_dev="$(findmnt -n -o SOURCE --target "$STAGE2_DIR" 2>/dev/null || findmnt -n -o SOURCE / 2>/dev/null)"
fi
[ -n "$data_dev" ] && data_uuid="$(blkid -s UUID -o value "$data_dev" 2>/dev/null || echo "")"
[ -n "$data_uuid" ] && search_directive="${search_directive}"$'\n'"    search --no-floppy --fs-uuid --set=root $data_uuid"

firmware_modules=""
if [ "$FIRMWARE_MODE" = "UEFI" ]; then
    firmware_modules="insmod efi_gop"$'\n'"    insmod efi_uga"
else
    firmware_modules="insmod biosdisk"$'\n'"    insmod vbe"
fi

cat > /tmp/winboxes-grub-entry <<GRUBENTRY

### BEGIN WINBOXES ###
menuentry "${GRUB_MENU_TITLE}" --id ${GRUB_MENU_ID} {
    insmod part_msdos
    insmod part_gpt
    insmod ext2
    insmod ext4
    insmod xfs
    insmod btrfs
    insmod gzio
    insmod normal
    insmod linux
    ${firmware_modules}

    ${search_directive}

    echo 'Loading WinBoxes kernel...'
    linux /${STAGE2_GRUB_REL}/winboxes-vmlinuz \\
        init=/init \\
        target_disk=${TARGET_DISK} \\
        image_file=/${STAGE2_GRUB_REL}/winboxes-disk.img \\
        image_checksum=${checksum} \\
        data_fs_uuid=${data_uuid} \\
        selected_uefi=${SELECTED_UEFI} \\
        console=tty0 console=ttyS0,115200n8

    echo 'Loading WinBoxes initramfs...'
    initrd /${STAGE2_GRUB_REL}/winboxes-initrd.img
}
### END WINBOXES ###
GRUBENTRY

remove_existing_entry "$GRUB_CFG"
first_menu_line=$(grep -nm1 '^menuentry ' "$GRUB_CFG" | cut -d: -f1)
if [ -n "$first_menu_line" ]; then
    head -n $((first_menu_line - 1)) "$GRUB_CFG" > "${GRUB_CFG}.tmp"
    cat /tmp/winboxes-grub-entry >> "${GRUB_CFG}.tmp"
    tail -n +${first_menu_line} "$GRUB_CFG" >> "${GRUB_CFG}.tmp"
    mv "${GRUB_CFG}.tmp" "$GRUB_CFG"
    log_success "GRUB entry inserted as FIRST boot entry"
else
    cat /tmp/winboxes-grub-entry >> "$GRUB_CFG"
    log_success "GRUB entry appended"
fi
rm -f /tmp/winboxes-grub-entry

# Ensure GRUB shows menu (timeout 5s if currently 0)
if [ -f /etc/default/grub ]; then
    if grep -q '^GRUB_TIMEOUT=0' /etc/default/grub 2>/dev/null; then
        cp /etc/default/grub /etc/default/grub.winboxes.bak
        sed -i 's/^GRUB_TIMEOUT=0/GRUB_TIMEOUT=5/' /etc/default/grub
        log_info "GRUB timeout set to 5s (was 0)"
    fi
fi

# grub-reboot (one-time boot) with fallbacks
if grub-reboot "$GRUB_MENU_ID" 2>/dev/null; then
    log_success "grub-reboot set: will boot $GRUB_MENU_ID once, then revert"
else
    log_warn "grub-reboot failed, using grub-set-default"
    grub-set-default "$GRUB_MENU_ID" 2>/dev/null || \
        grub-editenv /boot/grub/grubenv set saved_entry="$GRUB_MENU_ID" 2>/dev/null || true
fi
grub2-reboot "$GRUB_MENU_ID" 2>/dev/null || true
grub2-set-default "$GRUB_MENU_ID" 2>/dev/null || true

# ===========================================================================
#  STEP 10 — show IPv4 + final confirmation + reboot
#     Since WinBoxes has no SAAS tracking URL, show the IPv4 the operator
#     needs to reconnect after the box comes back up.
# ===========================================================================
echo
echo "$(bold "$TOOL_NAME") deployment prepared."
echo "  Image : $SELECTED_NAME"
echo "  Disk  : $TARGET_DISK ($DISK_SIZE_GB GB)"
echo "  Mode  : $([ "$SELECTED_UEFI" = yes ] && echo UEFI || echo BIOS)"
echo

echo "$(yellow 'Save this information — you will need it to access the VPS after reboot.')"
echo "  IPv4 addresses:"
ip -4 -o addr show 2>/dev/null | awk '$2 != "lo" { print "    " $2 " -> " $4 }'
[ -n "$DEFAULT_GW" ] && echo "  Default gateway : $DEFAULT_GW"
echo
echo "$(yellow 'After reboot, GRUB will boot WinBoxes Stage-2 which dd'"'"'s the image,')"
echo "$(yellow 'fixes UEFI/BIOS boot, then reboots into Windows automatically.')"
echo "If the VPS becomes unreachable, use your provider's console / VNC to verify boot."
echo

if $NO_REBOOT; then
    log_info "=== NO-REBOOT MODE: prepared, NOT rebooting ==="
    log_info "To trigger manually: grub-reboot $GRUB_MENU_ID && reboot"
    log_info "To verify GRUB entry: grep -A20 'BEGIN WINBOXES' $GRUB_CFG"
    exit 0
fi

read -r -p "Continue Reboot (Y/n) " REBOOTNOW
case "$REBOOTNOW" in
    n|N|no|NO) echo "Reboot skipped. Run 'reboot' manually when ready."; exit 0 ;;
esac

sync
sleep 2
# Reboot: try systemctl when systemd is PID 1, otherwise use direct commands.
# Order: reboot → shutdown → systemctl → sysrq (last resort)
if $SYSTEMD_RUNNING; then
    systemctl reboot 2>/dev/null || reboot 2>/dev/null || shutdown -r now 2>/dev/null || true
else
    reboot 2>/dev/null || shutdown -r now 2>/dev/null || /sbin/reboot 2>/dev/null || \
        systemctl reboot 2>/dev/null || echo b > /proc/sysrq-trigger 2>/dev/null || true
fi

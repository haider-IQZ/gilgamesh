#!/usr/bin/env bash
#
# Gilgamesh installer: run it as root from the official Arch Linux ISO.
#
#   bash <(curl -fsSL https://raw.githubusercontent.com/haider-IQZ/gilgamesh/main/installer/install.sh)
#   install.sh --dry-run    ask everything, print what would run, change nothing
#
# Asks a few questions (keyboard, user, password, hostname, timezone, disk), then ERASES the
# chosen disk and installs Gilgamesh on it: GPT with a 1 GiB EFI partition + XFS root, GRUB,
# the packages in installer/packages (+ packages-nvidia for supported NVIDIA GPUs), the
# system/ overlay, and the user's Hyprland / Quickshell / fish config.
# Started with bash <(...) rather than curl | bash, so stdin stays the terminal for gum.

set -Eeuo pipefail

TARBALL=https://github.com/haider-IQZ/gilgamesh/archive/refs/heads/main.tar.gz
LOG=/tmp/gilgamesh-install.log
TARGET=/mnt
MIN_DISK_BYTES=$((40 * 1000 * 1000 * 1000))   # 40 GB
# TODO(phase 2): linux-tkg from our own [gilgamesh] repo. That also means adding [gilgamesh]
# (with its signing key) above [core] in both pacman.conf files, before pacstrap.
KERNEL=${KERNEL:-linux}                         # its -headers package is installed too (DKMS)

GREEN='#99ad6a' RED='#cf6a4c' GRAY='#888888'

DRY_RUN=false
case ${1:-} in
--dry-run) DRY_RUN=true ;;
"") ;;
-h | --help) echo "usage: install.sh [--dry-run]   (--dry-run: ask everything, change nothing)"; exit 0 ;;
*) echo "usage: install.sh [--dry-run]" >&2; exit 1 ;;
esac

die() { printf '\n  %s\n\n' "$*" >&2; exit 1; }

# label | XKB layout (Hyprland) | XKB options | console keymap (loadkeys, vconsole.conf)
KEYBOARDS="\
English (US)|us||us
English (UK)|gb||uk
German|de||de-latin1
French|fr||fr-latin1
Spanish|es||es
Italian|it||it
Portuguese|pt||pt-latin1
Portuguese (Brazil)|br||br-abnt2
Russian + English (Alt+Shift switches)|us,ru|grp:alt_shift_toggle|us
Arabic + English (Alt+Shift switches)|us,ara|grp:alt_shift_toggle|us
Turkish|tr||trq
Polish|pl||pl
Swedish|se||sv-latin1
Norwegian|no||no-latin1
Danish|dk||dk-latin1
Japanese|jp||jp106"

# accounts that base or our packages already create (useradd would fail on them)
RESERVED_USERS='^(wheel|audio|video|input|disk|storage|optical|render|kvm|adm|log|sys|network|power|users|root|bin|daemon|mail|ftp|http|nobody|dbus|uuidd|polkitd|rtkit|git|avahi|colord|alpm|tss|geoclue|usbmux|nvidia-persistenced|systemd-.*)$'

INSTALL_STATE=untouched
CURRENT_STEP=questions
WORKER_PID="" SPINNER_PID="" MOUNT_JOURNAL=""
LIVE_DISKS=""
CLEANUP_STARTED=false LOG_STARTED=false
WRITE_MARKER=""

stop_workers() {
    local pid attempt
    for pid in "$WORKER_PID" "$SPINNER_PID"; do
        [[ -n $pid ]] || continue
        kill -TERM -- "-$pid" 2>/dev/null || true
    done
    for pid in "$WORKER_PID" "$SPINNER_PID"; do
        [[ -n $pid ]] || continue
        # pacstrap and arch-chroot need time to release their nested mounts.
        for attempt in {1..100}; do
            kill -0 -- "-$pid" 2>/dev/null || break
            sleep 0.1
        done
        kill -KILL -- "-$pid" 2>/dev/null || true
        wait "$pid" 2>/dev/null || true
    done
    WORKER_PID="" SPINNER_PID=""
}

cleanup_mounts() {
    local mounts target source id actual actual_source actual_id status attempt rc=0
    local -A seen=()
    [[ -n $MOUNT_JOURNAL && -f $MOUNT_JOURNAL ]] || return 0
    mounts=$(tac "$MOUNT_JOURNAL") || return 1
    while read -r target source id; do
        [[ -n $target && -z ${seen[$target]:-} ]] || continue
        seen[$target]=yes
        for attempt in {1..4}; do
            status=0
            actual=$(findmnt -rn -M "$target" -o SOURCE,ID) || status=$?
            if (( status == 1 )) && [[ -z $actual ]]; then break; fi
            (( status == 0 )) || return 1
            read -r actual_source actual_id <<<"$actual"
            if [[ $actual_source != "$source" || ( $id != pending && $actual_id != "$id" ) ]]; then
                printf 'Refusing to unmount changed mount %s at %s\n' "$actual" "$target" >&2
                rc=1
                break
            fi
            # pacstrap -K can leave keyring daemons holding the target open.
            if [[ $target == "$TARGET" && $attempt == 1 && -d $TARGET/etc/pacman.d/gnupg ]]; then
                gpgconf --homedir "$TARGET/etc/pacman.d/gnupg" --kill all ||
                    printf 'Could not stop target keyring daemons.\n' >&2
            fi
            if umount "$target"; then break; fi
            if (( attempt == 4 )); then
                printf 'Could not unmount %s. Run: umount -R %s before retrying the installer.\n' "$target" "$TARGET" >&2
                rc=1
            else
                sleep 1
            fi
        done
    done <<<"$mounts"
    return "$rc"
}

on_exit() {
    local rc=$?
    trap '' INT TERM HUP
    $CLEANUP_STARTED && return
    CLEANUP_STARTED=true
    trap - EXIT
    stop_workers
    if [[ $INSTALL_STATE != installed && -n $WRITE_MARKER && -s $WRITE_MARKER ]]; then
        INSTALL_STATE=installing
    fi
    if ! cleanup_mounts; then
        printf 'Could not unmount all installer mounts. Check them before rebooting.\n' >&2
        rc=1
    fi
    case $INSTALL_STATE in
        dry-done) printf 'Dry run complete. Nothing was changed.\n' ;;
        untouched) printf 'Installer stopped. Nothing was changed.\n' ;;
        live) printf 'Installer stopped; live environment prepared. No disk writes started.\n' ;;
        installing) printf 'Install stopped at step: %s\nLog: %s\nThe disk may be partially installed.\n' "$CURRENT_STEP" "$LOG" ;;
        installed) printf 'Installed successfully; reboot when ready. Log: %s\n' "$LOG" ;;
    esac
    exit "$rc"
}

on_signal() {
    trap '' INT TERM HUP
    printf '\nInterrupted at step: %s\n' "$CURRENT_STEP" >&2
    if $LOG_STARTED; then printf 'Log: %s\n' "$LOG" >&2; fi
    exit "$1"
}
trap on_exit EXIT
trap 'on_signal 130' INT
trap 'on_signal 143' TERM
trap 'on_signal 129' HUP

# ---------------------------------------------------------------- preflight (live ISO)

# A dry run must not download or create even temporary files.
script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
if [[ -d $script_dir/../system ]]; then
    SRC=$(cd "$script_dir/.." && pwd)
else
    $DRY_RUN && die "--dry-run requires a local checkout; downloading would write temporary files."
    INSTALL_STATE=live
    SRC=$(mktemp -d /tmp/gilgamesh.XXXXXX)
    curl -fsSL "$TARBALL" | tar -xz -C "$SRC" --strip-components=1 ||
        die "Could not download $TARBALL"
fi

if ! $DRY_RUN; then
    (( EUID == 0 )) || die "Run the installer as root (the Arch ISO logs you in as root)."
    [[ -d /sys/firmware/efi ]] || die "This machine booted in legacy BIOS mode. Gilgamesh needs UEFI:
  enable UEFI in the firmware settings (for a VM: OVMF firmware), then boot the ISO again."
    curl -fsS --max-time 10 -o /dev/null https://archlinux.org/ ||
        die "No internet connection. Connect with iwctl, then start the installer again."
    INSTALL_STATE=live
    sed -i '/^#\[multilib\]/,/^#Include/ s/^#//' /etc/pacman.conf
    echo "Preparing the live system..."
    pacman -Sy --noconfirm --needed archlinux-keyring gum >/dev/null ||
        die "Could not install gum on the live system (pacman failed)."
fi
command -v gum >/dev/null || die "gum is not installed (for a local dry run: nix-shell -p gum)."

for f in installer/logo.txt installer/packages installer/packages-nvidia system hypr/hyprland.lua \
    quickshell fish/colors.fish fish/prompt.fish fish/starship.toml scripts/gilgamesh-dns \
    etc/sudoers.d/gilgamesh-dns; do
    [[ -e $SRC/$f ]] || die "Missing $f in $SRC (incomplete download or checkout?)"
done

# package list: one per line, # comments
read_list() { awk '{ sub(/#.*/, "") } NF { print $1 }' "$1"; }
packages=$(read_list "$SRC/installer/packages") || die "Cannot read package list"
packages_nvidia=$(read_list "$SRC/installer/packages-nvidia") || die "Cannot read NVIDIA package list"
[[ -n $packages && -n $packages_nvidia ]] || die "Package lists must not be empty"
mapfile -t PACKAGES <<<"$packages"
mapfile -t PACKAGES_NVIDIA <<<"$packages_nvidia"

pci=$(lspci -nn) || die "Cannot detect graphics hardware with lspci"
NVIDIA=false NVIDIA_OLD=false
while IFS= read -r gpu; do
    if [[ $gpu =~ \[(0300|0302)\] && ${gpu,,} =~ \[10de:([0-9a-f]{4})\] ]]; then
        device=${BASH_REMATCH[1]}
        # Heuristic: IDs >= 0x1e00 are Turing+; odd SKUs can break this ordering.
        if (( 16#$device >= 16#1e00 )); then NVIDIA=true; else NVIDIA_OLD=true; fi
    fi
done <<<"$pci"
if $NVIDIA_OLD; then NVIDIA=false; fi
vendor=$(awk '$1 == "vendor_id" { print $3; exit }' /proc/cpuinfo) || die "Cannot detect CPU vendor"
MICROCODE=""
case $vendor in
    AuthenticAMD) MICROCODE=amd-ucode ;;
    GenuineIntel) MICROCODE=intel-ucode ;;
esac

# ---------------------------------------------------------------- screen

LOGO=$(<"$SRC/installer/logo.txt")
LOGO_WIDTH=0
while IFS= read -r line; do
    if (( ${#line} > LOGO_WIDTH )); then LOGO_WIDTH=${#line}; fi
done <<<"$LOGO"

export GUM_CHOOSE_CURSOR_FOREGROUND=$GREEN GUM_CHOOSE_HEADER_FOREGROUND=$GRAY
export GUM_CHOOSE_SELECTED_FOREGROUND=$GREEN
export GUM_FILTER_INDICATOR_FOREGROUND=$GREEN GUM_FILTER_MATCH_FOREGROUND=$GREEN
export GUM_FILTER_HEADER_FOREGROUND=$GRAY GUM_FILTER_PROMPT_FOREGROUND=$GREEN
export GUM_INPUT_CURSOR_FOREGROUND=$GREEN GUM_INPUT_PROMPT_FOREGROUND=$GREEN
export GUM_INPUT_HEADER_FOREGROUND=$GRAY
export GUM_CONFIRM_PROMPT_FOREGROUND=$GREEN GUM_CONFIRM_SELECTED_BACKGROUND=$GREEN
export GUM_CONFIRM_SELECTED_FOREGROUND=0
export GUM_SPIN_SPINNER_FOREGROUND=$GREEN
export GUM_TABLE_BORDER_FOREGROUND=$GRAY GUM_TABLE_HEADER_FOREGROUND=$GREEN

# Everything sits in one column, left-aligned with the centered logo. Measured on every
# screen: the console can still grow after boot (framebuffer / VM window).
measure() {
    local size
    size=$(stty size 2>/dev/null </dev/tty || echo "24 80")
    ROWS=${size% *} COLS=${size#* }
    PAD=$(( (COLS - LOGO_WIDTH) / 2 ))
    if (( PAD < 2 )); then PAD=2; fi
    PAD_SPACES=$(printf '%*s' "$PAD" "")
    LIST_HEIGHT=$(( ROWS - 15 ))
    if (( LIST_HEIGHT < 5 )); then LIST_HEIGHT=5; fi
    local p="0 0 0 $PAD"
    export GUM_CHOOSE_PADDING=$p GUM_FILTER_PADDING=$p GUM_INPUT_PADDING=$p GUM_CONFIRM_PADDING=$p
    export GUM_SPIN_PADDING=$p
}

say() { gum style --padding "0 0 0 $PAD" "$@"; }

# screen TITLE [ERROR]: clear, logo, title, and a red line when the last answer was refused
screen() {
    measure
    printf '\033[H\033[2J'
    gum style --foreground "$GREEN" --padding "1 0 1 $PAD" "$LOGO"
    if $DRY_RUN; then say --foreground "$GRAY" "Dry run: nothing will be changed."; echo; fi
    say --bold "$1"
    if [[ -n ${2:-} ]]; then say --foreground "$RED" "$2"; fi
    echo
}

cancel() { exit 130; }

# Discard keys typed while the installation was running, including a stray Enter.
drain_input() {
    while IFS= read -r -s -n 1 -t 0.05; do :; done </dev/tty
}

# gum confirm: 0 yes, 1 no, anything else (Ctrl+C) stops the installer
confirm() {
    local rc=0
    if [[ $INSTALL_STATE == installing || $INSTALL_STATE == installed ]]; then drain_input; fi
    gum confirm "$@" || rc=$?
    (( rc <= 1 )) || cancel
    return "$rc"
}

# ---------------------------------------------------------------- questions

ask_keyboard() {
    local labels choice row error=""
    labels=$(cut -d'|' -f1 <<<"$KEYBOARDS")
    while true; do
        screen "Keyboard layout" "$error"
        choice=$(gum choose --height "$LIST_HEIGHT" --header "Used for the console and the desktop" \
            ${KB_LABEL:+--selected "$KB_LABEL"} <<<"$labels") || cancel
        row=$(awk -F'|' -v c="$choice" '$1 == c' <<<"$KEYBOARDS") || die "Cannot read keyboard layouts"
        [[ -n $row ]] || die "Unknown keyboard layout"
        IFS='|' read -r KB_LABEL KB_LAYOUT KB_OPTIONS KB_KEYMAP <<<"$row"
        if ! $DRY_RUN && [[ $(tty) == /dev/tty[0-9]* ]]; then
            INSTALL_STATE=live
            if ! loadkeys "$KB_KEYMAP"; then
                error="Could not apply $KB_KEYMAP. Choose a working layout before entering your password."
                continue
            fi
        fi
        return
    done
}

name_in_use() {
    local database rc
    for database in passwd group; do
        rc=0
        getent "$database" "$1" >/dev/null || rc=$?
        case $rc in
            0) return 0 ;;
            2) ;;
            *) die "Cannot check live $database names" ;;
        esac
    done
    return 1
}

ask_username() {
    local error=${1:-} name
    while true; do
        screen "Username" "$error"
        if [[ $INSTALL_STATE == installing ]]; then drain_input; fi
        name=$(gum input --header "Lowercase letters, digits, - and _" --placeholder "e.g. enkidu" \
            --value "${USERNAME:-}" --char-limit 32) || cancel
        if [[ ! $name =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]; then
            error="\"$name\" won't work: start with a lowercase letter or _, then a-z 0-9 _ -"
        elif [[ $name =~ $RESERVED_USERS ]] || name_in_use "$name"; then
            error="\"$name\" is an existing or reserved account/group name, pick another one"
        else
            USERNAME=$name; return
        fi
    done
}

ask_password() {
    local error="" first second
    while true; do
        screen "Password for $USERNAME" "$error"
        say --foreground "$GRAY" "Also used for sudo. The root account stays locked."
        echo
        first=$(gum input --password --header "Password" --placeholder "") || cancel
        [[ -n $first ]] || { error="The password can't be empty"; continue; }
        screen "Password for $USERNAME"
        say --foreground "$GRAY" "Also used for sudo. The root account stays locked."
        echo
        second=$(gum input --password --header "Same password again" --placeholder "") || cancel
        [[ $first == "$second" ]] || { error="The passwords didn't match, try again"; continue; }
        PASSWORD=$first; return
    done
}

ask_hostname() {
    local error="" name
    while true; do
        screen "Computer name (hostname)" "$error"
        name=$(gum input --header "How this machine shows up on the network" \
            --value "${HOSTNAME_NEW:-gilgamesh}" --char-limit 63) || cancel
        name=${name,,}
        if [[ $name =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]]; then
            HOSTNAME_NEW=$name; return
        fi
        error="\"$name\" won't work: letters, digits and - only, not at the start or end"
    done
}

# straight from the tz database, no geolocation lookup
timezones() {
    timedatectl list-timezones 2>/dev/null ||
        awk '$1 == "Z" { print $2 } $1 == "L" { print $3 }' /usr/share/zoneinfo/tzdata.zi | sort
}

ask_timezone() {
    local tz zones
    screen "Timezone"
    zones=$(timezones) || die "Cannot list timezones"
    [[ -n $zones ]] || die "Timezone list is empty"
    tz=$(gum filter --height "$LIST_HEIGHT" --placeholder "Type a timezone, e.g. Etc/UTC" \
        --header "Type to search, Enter to pick" --value "${TIMEZONE:-}" <<<"$zones") || cancel
    [[ -n $tz ]] || cancel
    TIMEZONE=$tz
}

# Capture the entire graph before deciding which nodes may be written.
read_inventory() {
    local name type parent mounts
    INVENTORY=$(lsblk -nrpo NAME,TYPE,PKNAME,MOUNTPOINTS) || die "Cannot inventory block devices"
    [[ -n $INVENTORY ]] || die "Block device inventory is empty"
    while read -r name type parent mounts; do
        [[ $name == /dev/* && -n $type ]] || die "Invalid block device inventory"
        if [[ $type == part && $parent != /dev/* ]]; then die "Partition $name has no parent in inventory"; fi
    done <<<"$INVENTORY"
}

live_ancestors() {
    local dev=$1 name type parent mounts found=false backing source candidate
    dev=$(readlink -f "$dev") || die "Cannot resolve live device $dev"
    [[ $dev == /dev/* ]] || die "Invalid live device $dev"
    [[ ${LIVE_VISITED[$dev]:-} != visiting ]] || die "Cycle in live device ancestry at $dev"
    [[ ${LIVE_VISITED[$dev]:-} != complete ]] || return 0
    LIVE_VISITED[$dev]=visiting
    while read -r name type parent mounts; do
        name=$(readlink -f "$name") || die "Cannot resolve inventory device $name"
        [[ $name == "$dev" ]] || continue
        found=true
        if [[ $type == disk || $type == rom ]]; then
            LIVE_DISKS+="$name"$'\n'
        elif [[ $type == loop ]]; then
            backing=$(losetup -n --raw -O BACK-FILE "$dev") || backing=""
            if [[ -z $backing ]]; then
                backing=$(cat "/sys/class/block/${dev##*/}/loop/backing_file") ||
                    die "Cannot resolve backing file for live loop $dev"
            fi
            [[ -n $backing ]] || die "No backing file for live loop $dev"
            printf -v backing '%b' "$backing"
            # Archiso may mount an ISO by a path relative to img_dev.
            source=""
            for candidate in "$backing" "/run/archiso/img_dev/${backing#/}"; do
                [[ -e $candidate ]] || continue
                source=$(findmnt -rn -T "$candidate" -o SOURCE) || die "Cannot locate live ISO backing filesystem"
                [[ -n $source ]] && break
            done
            [[ -n $source ]] || die "Cannot locate live ISO backing file: $backing"
            live_ancestors "${source%%\[*}"
        elif [[ $parent == /dev/* ]]; then
            live_ancestors "$parent"
        else
            die "Cannot identify physical ancestor of live device $dev"
        fi
    done <<<"$INVENTORY"
    $found || die "Live device $dev is missing from block inventory"
    LIVE_VISITED[$dev]=complete
}

protect_live_disks() {
    local path source token cmdline rc
    local -a tokens=()
    local -A LIVE_VISITED=()
    for path in /run/archiso/bootmnt /run/archiso/img_dev; do
        rc=0
        source=$(findmnt -rn -M "$path" -o SOURCE) || rc=$?
        (( rc <= 1 )) || die "Cannot inspect live mount $path"
        if [[ -n $source ]]; then live_ancestors "${source%%\[*}"; fi
    done
    # Keep the boot identity when copy-to-RAM has already unmounted the medium.
    cmdline=$(cat /proc/cmdline) || die "Cannot read boot device information"
    read -ra tokens <<<"$cmdline"
    for token in "${tokens[@]}"; do
        case $token in
            archisodevice=*|img_dev=*) source=${token#*=} ;;
            archisolabel=*) source="LABEL=${token#*=}" ;;
            archisosearchuuid=*) source="UUID=${token#*=}" ;;
            *) continue ;;
        esac
        if [[ $source != /dev/* ]]; then
            source=$(findfs "$source") || die "Cannot resolve retained live boot device $token"
        fi
        live_ancestors "$source"
    done
    if ! $DRY_RUN && [[ -z $LIVE_DISKS ]]; then
        die "Cannot identify the live medium's physical disks. Refusing to install."
    fi
}

check_target_mounts() {
    local mounts path
    mounts=$(findmnt -rn -o TARGET) || die "Cannot inspect current mounts"
    while IFS= read -r path; do
        if [[ $path == "$TARGET" || $path == "$TARGET/"* ]]; then
            die "Unrelated mount at $path. Unmount it yourself before installing."
        fi
    done <<<"$mounts"
}

validate_disk() {
    local name type parent mounts node holder directory swaps swap rest found=false
    local -a nodes=()
    read_inventory
    protect_live_disks
    check_target_mounts
    while IFS= read -r node; do
        [[ $node != "$DISK" ]] || die "$DISK backs the live medium; refusing to erase it"
    done <<<"$LIVE_DISKS"
    WIPE_PARTS=()
    while read -r name type parent mounts; do
        if [[ $name == "$DISK" ]]; then
            [[ $type == disk ]] || die "$DISK is not a whole disk"
            found=true
        elif [[ $parent == "$DISK" && $type == part ]]; then
            WIPE_PARTS+=("$name")
        else
            continue
        fi
        # A whole disk with no PKNAME puts its mountpoint in the third field.
        if [[ $name == "$DISK" && -n $parent ]]; then mounts=$parent; fi
        [[ -z $mounts ]] || die "$name is mounted or active swap ($mounts)"
        nodes+=("$name")
    done <<<"$INVENTORY"
    $found || die "$DISK is absent from the inventory"
    swaps=$(awk 'NR > 1 { print $1 }' /proc/swaps) || die "Cannot inspect active swap"
    for node in "${nodes[@]}"; do
        directory=/sys/class/block/${node##*/}/holders
        if [[ $node == "$DISK" ]]; then directory=/sys/block/${node##*/}/holders; fi
        [[ -d $directory && -r $directory && -x $directory ]] || die "Cannot inspect holders for $node"
        for holder in "$directory"/*; do
            [[ ! -e $holder ]] || die "$node has an active holder: ${holder##*/} (md, LVM or crypt)"
        done
        while read -r name type parent rest; do
            if [[ $parent == "$node" && $type != part ]]; then
                die "$node has an active mapped descendant: $name"
            fi
        done <<<"$INVENTORY"
        while IFS= read -r swap; do
            [[ -n $swap ]] || continue
            swap=$(readlink -f "$swap") || die "Cannot resolve active swap"
            [[ $swap != "$node" ]] || die "$node is active swap"
        done <<<"$swaps"
    done
    local ro
    ro=$(lsblk -dnro RO "$DISK") || die "Cannot check disk write protection"
    [[ $ro == 0 ]] || die "$DISK is read-only"
}

disk_identity() {
    local identity seq=unavailable major size
    identity=$(lsblk -dnpo MAJ:MIN,SERIAL,WWN "$DISK") || die "Cannot read identity of $DISK"
    read -r major _ <<<"$identity"
    [[ $major =~ ^[0-9]+:[0-9]+$ && $identity != *$'\n'* ]] ||
        die "$DISK needs a readable major:minor for safe confirmation"
    size=$(lsblk -bdno SIZE "$DISK") || die "Cannot read disk size for $DISK"
    [[ $size =~ ^[0-9]+$ ]] || die "Invalid disk size for $DISK"
    if [[ -e /sys/block/${DISK##*/}/diskseq ]]; then
        seq=$(cat "/sys/block/${DISK##*/}/diskseq") || die "Cannot read disk sequence for $DISK"
        [[ $seq =~ ^[0-9]+$ ]] || die "Invalid disk sequence for $DISK"
    fi
    printf '%s\n%s\n%s\n' "$identity" "$size" "$seq"
}

ask_disk() {
    local error="" name type ro size model choice bytes options disks
    local -A label=()
    read_inventory
    protect_live_disks
    check_target_mounts
    disks=$(lsblk -dpno NAME,TYPE,RO,SIZE,MODEL) || die "Cannot list disks"
    [[ -n $disks ]] || die "Disk inventory is empty"
    options=""
    while read -r name type ro size model; do
        [[ $type == disk && $ro == 0 && $name != /dev/zram* ]] || continue
        if [[ $'\n'$LIVE_DISKS == *$'\n'"$name"$'\n'* ]]; then continue; fi
        label[$name]=$(printf '%-14s %7s  %s' "$name" "$size" "$model")
        options+=${label[$name]}$'\n'
    done <<<"$disks"
    [[ -n $options ]] || die "No disk found to install on."
    while true; do
        screen "Disk to install on" "$error"
        say --foreground "$RED" "Everything on the disk you pick will be erased."
        echo
        choice=$(gum choose --height "$LIST_HEIGHT" --header "Disks" \
            ${DISK:+--selected "${label[$DISK]:-}"} <<<"${options%$'\n'}") || cancel
        name=${choice%% *}
        [[ -n ${label[$name]:-} ]] || die "Invalid disk selection"
        bytes=$(lsblk -bdno SIZE "$name") || die "Cannot read disk size"
        [[ $bytes =~ ^[0-9]+$ ]] || die "Invalid disk size"
        if (( bytes < MIN_DISK_BYTES )); then
            error="$name is too small: Gilgamesh needs at least 40 GB"
            continue
        fi
        DISK=$name DISK_LABEL=$(tr -s ' ' <<<"$choice")
        if ! error=$(validate_disk 2>&1); then continue; fi
        if ! CONFIRMED_IDENTITY=$(disk_identity 2>&1); then
            error=$CONFIRMED_IDENTITY
            continue
        fi
        return
    done
}

summary() {
    local graphics="no NVIDIA GPU found"
    if $NVIDIA; then graphics="NVIDIA Turing+ (open drivers included)"; fi
    if $NVIDIA_OLD; then graphics="Older NVIDIA: kernel nouveau; no NVIDIA packages"; fi
    screen "Summary"
    if $NVIDIA_OLD; then
        say --foreground "$RED" "Older NVIDIA GPU detected: nvidia-open needs Turing or newer."
        say "Installing with the kernel's nouveau driver so the desktop can start."
        echo
    fi
    # gum table ignores padding when printing, so indent by hand
    printf '%s\t%s\n' \
        Keyboard "$KB_LABEL" \
        Username "$USERNAME" \
        Password "********" \
        Hostname "$HOSTNAME_NEW" \
        Timezone "$TIMEZONE" \
        Disk "$DISK_LABEL" \
        Graphics "$graphics" \
        Kernel "$KERNEL" |
        gum table -p -s $'\t' --lazy-quotes -c "Setting,Value" | sed "s/^/$PAD_SPACES/"
    echo
}

questions() {
    while true; do
        ask_keyboard
        ask_username
        ask_password
        ask_hostname
        ask_timezone
        ask_disk
        summary
        confirm --affirmative "Yes" --negative "No, change it" "Does this look right?" || continue

        validate_disk
        [[ $(disk_identity) == "$CONFIRMED_IDENTITY" ]] || die "Disk identity changed before confirmation"
        screen "Last chance"
        say --foreground "$RED" "Everything on $DISK_LABEL will be erased."
        say --foreground "$RED" "This can't be undone."
        echo
        confirm --default=false --affirmative "Erase and install" --negative "No" \
            "Erase everything on $DISK?" && return
    done
}

# ---------------------------------------------------------------- install helpers

# a command line as you'd type it (single quotes only where needed), for the log and the dry run
show() {
    local a sq="'" esc="'\\''" out=()
    for a in "$@"; do
        if [[ $a =~ ^[[:alnum:]_./:=,+@%-]+$ ]]; then out+=("$a"); else out+=("'${a//$sq/$esc}'"); fi
    done
    printf '%s\n' "${out[*]}"
}

# x CMD...: run it (logged), or only print it in a dry run
x() {
    if $DRY_RUN; then show "$@"; return 0; fi
    printf '$ '; show "$@"
    "$@"
}

in_target() { x arch-chroot "$TARGET" "$@"; }

# write_file FILE [MODE] <content   /   append FILE <content
write_file() {
    local file=$1 mode=${2:-644}
    if $DRY_RUN; then echo "write $file ($mode):"; sed 's/^/    | /'; return 0; fi
    echo "\$ write $file"
    mkdir -p "$(dirname "$file")"
    cat >"$file"
    chmod "$mode" "$file"
}
append() {
    if $DRY_RUN; then echo "append to $1:"; sed 's/^/    | /'; return 0; fi
    echo "\$ append to $1"
    cat >>"$1"
}

# set_conf FILE KEY VALUE: KEY=VALUE, replacing the line (commented out or not) if there is one
set_conf() {
    local file=$1 key=$2 value=$3
    if $DRY_RUN; then echo "set $key=$value in $file"; return 0; fi
    echo "\$ set $key=$value in $file"
    if grep -qE "^#?[[:space:]]*$key=" "$file"; then
        sed -i -E "s|^#?[[:space:]]*$key=.*|$key=$value|" "$file"
    else
        printf '%s=%s\n' "$key" "$value" >>"$file"
    fi
}

enable_multilib() { x sed -i '/^#\[multilib\]/,/^#Include/ s/^#//' "$1"; }

# p1/p2 of the chosen disk (nvme0n1 -> nvme0n1p1, sda -> sda1)
part() {
    if [[ $DISK =~ [0-9]$ ]]; then echo "${DISK}p$1"; else echo "${DISK}$1"; fi
}

# Job control gives each worker its own process group, including its children.
step() {
    local title=$1 rc=0
    shift
    CURRENT_STEP=$title
    if $DRY_RUN; then
        say --foreground "$GREEN" "$title"
        "$@" | sed "s/^/$PAD_SPACES  /"
        return 0
    fi
    printf '\n==> %s\n' "$title" >>"$LOG"
    set -m
    ( trap - ERR EXIT INT TERM HUP; set +m; "$@" ) >>"$LOG" 2>&1 </dev/null &
    WORKER_PID=$!
    # shellcheck disable=SC2016  # $1 is for the inner bash
    gum spin --spinner dot --title "$title" -- \
        bash -c 'while kill -0 "$1" 2>/dev/null; do sleep 0.2; done' _ "$WORKER_PID" &
    SPINNER_PID=$!
    set +m
    wait "$SPINNER_PID" || rc=$?
    SPINNER_PID=""
    if (( rc != 0 )); then
        printf 'Progress display failed at step: %s\nLog: %s\n' "$title" "$LOG" >&2
        exit "$rc"
    fi
    wait "$WORKER_PID" || rc=$?
    WORKER_PID=""
    if (( rc != 0 )); then
        printf 'Step failed: %s\nLog: %s\n' "$title" "$LOG" >&2
        tail -n 25 "$LOG" >&2
        exit "$rc"
    fi
    say "$(gum style --foreground "$GREEN" "✓") $title"
}

# ---------------------------------------------------------------- install steps

partition_disk() {
    local p identity
    validate_disk
    identity=$(disk_identity) || die "Cannot recheck disk identity"
    [[ $identity == "$CONFIRMED_IDENTITY" ]] || die "Disk identity changed since confirmation; refusing to wipe $DISK"
    if ! $DRY_RUN; then printf 'started\n' >"$WRITE_MARKER"; fi
    for p in "${WIPE_PARTS[@]}"; do x wipefs -a "$p"; done
    x wipefs -a "$DISK"
    # -o: fresh GPT. 8304 = "Linux x86-64 root", so systemd can find it by type
    x sgdisk -o -n 1:0:+1G -t 1:ef00 -c 1:EFI -n 2:0:0 -t 2:8304 -c 2:gilgamesh "$DISK"
    x partprobe "$DISK"
    if ! $DRY_RUN; then
        udevadm settle
        for p in {1..50}; do [[ -b $ESP_PART && -b $ROOT_PART ]] && break; sleep 0.2; done
        [[ -b $ESP_PART && -b $ROOT_PART ]] || { echo "partitions never showed up"; return 1; }
    fi
}

make_filesystems() {
    x mkfs.fat -F32 -n GIL_EFI "$ESP_PART"
    # no reverse-mapping btree / parent pointers: a few % faster when creating many files,
    # at the cost of online repair
    x mkfs.xfs -f -L gilgamesh -m rmapbt=0 -n parent=0 "$ROOT_PART"
    if ! $DRY_RUN; then
        local root_uuid esp_uuid
        root_uuid=$(blkid -s UUID -o value "$ROOT_PART") || die "Cannot read new root UUID"
        esp_uuid=$(blkid -s UUID -o value "$ESP_PART") || die "Cannot read new ESP UUID"
        [[ -n $root_uuid && -n $esp_uuid && $root_uuid != "$esp_uuid" ]] || die "Invalid new filesystem UUIDs"
        printf '%s %s\n' "$root_uuid" "$esp_uuid" >"$UUID_FILE"
    fi
}

mount_owned() {
    local source=$1 destination=$2 id
    shift 2
    if ! $DRY_RUN; then
        # Record intent before mount so interruption cannot lose a successful mount.
        printf '%s %s pending\n' "$destination" "$source" >>"$MOUNT_JOURNAL"
    fi
    x mount "$@" "$source" "$destination"
    if ! $DRY_RUN; then
        id=$(findmnt -rn -M "$destination" -o ID) || die "Cannot record mount at $destination"
        [[ $id =~ ^[0-9]+$ ]] || die "Invalid mount ID at $destination"
        printf '%s %s %s\n' "$destination" "$source" "$id" >>"$MOUNT_JOURNAL"
    fi
}

mount_target() {
    check_target_mounts
    mount_owned "$ROOT_PART" "$TARGET" -o noatime
    x mkdir -p "$TARGET/boot/efi"
    mount_owned "$ESP_PART" "$TARGET/boot/efi"    # only GRUB's EFI files; kernels stay on XFS
}

install_packages() {
    local pkgs=("$KERNEL" "$KERNEL-headers" "${PACKAGES[@]}")
    if [[ -n $MICROCODE ]]; then pkgs+=("$MICROCODE"); fi
    if $NVIDIA; then pkgs+=("${PACKAGES_NVIDIA[@]}"); fi
    x pacstrap -K "$TARGET" "${pkgs[@]}"
}

base_config() {
    enable_multilib "$TARGET/etc/pacman.conf"
    if $DRY_RUN; then
        echo "genfstab -U $TARGET (drop swap, verify root and ESP UUIDs) > $TARGET/etc/fstab"
    else
        local generated filtered
        [[ -n $ROOT_UUID && -n $ESP_UUID ]] || die "Missing UUIDs from filesystem creation"
        generated=$(genfstab -U "$TARGET") || die "genfstab failed"
        filtered=$(awk '$3 != "swap"' <<<"$generated") || die "Cannot filter fstab"
        awk -v root="UUID=$ROOT_UUID" -v esp="UUID=$ESP_UUID" '
            /^[[:space:]]*#/ || NF == 0 { next }
            $1 == root && $2 == "/" && $3 == "xfs" && NF == 6 { roots++; next }
            $1 == esp && $2 == "/boot/efi" && $3 == "vfat" && NF == 6 { esps++; next }
            { bad=1 }
            END { exit (bad || roots != 1 || esps != 1) }
        ' <<<"$filtered" || die "Refusing fstab: expected only this installation's root and ESP UUIDs"
        printf '%s\n' "$filtered" >"$TARGET/etc/fstab"
    fi
}

copy_overlay() {
    # tar rather than cp -a: cp would also give /etc, /usr, ... the checkout's owner and the
    # directories' modes. This way files land root-owned, existing directories stay as they
    # are, and symlinks (localsearch-3.service -> /dev/null) stay symlinks.
    if $DRY_RUN; then
        echo "tar -C $SRC/system -c . | tar -C $TARGET -x   (root-owned, existing dirs untouched)"
    else
        echo "\$ copy $SRC/system/ onto $TARGET/"
        tar -C "$SRC/system" --owner=0 --group=0 --mode='u=rwX,go=rX' -cf - . |
            tar -C "$TARGET" --no-overwrite-dir -xpf -
    fi
    if $NVIDIA; then
        # NVIDIA's 1 GB default prunes the DXVK/vkd3d shader caches -> recompile stutter
        append "$TARGET/etc/environment" <<'EOF'
__GL_SHADER_DISK_CACHE_SIZE=12000000000
__GL_SHADER_DISK_CACHE_SKIP_CLEANUP=1
EOF
    fi
    x install -Dm755 "$SRC/scripts/gilgamesh-dns" "$TARGET/usr/bin/gilgamesh-dns"
    x install -Dm440 "$SRC/etc/sudoers.d/gilgamesh-dns" "$TARGET/etc/sudoers.d/gilgamesh-dns"
    in_target visudo -cf /etc/sudoers.d/gilgamesh-dns
}

system_config() {
    x ln -sf "/usr/share/zoneinfo/$TIMEZONE" "$TARGET/etc/localtime"
    in_target hwclock --systohc
    x sed -i 's/^#en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' "$TARGET/etc/locale.gen"
    in_target locale-gen
    echo "LANG=en_US.UTF-8" | write_file "$TARGET/etc/locale.conf"
    echo "KEYMAP=$KB_KEYMAP" | write_file "$TARGET/etc/vconsole.conf"
    echo "$HOSTNAME_NEW" | write_file "$TARGET/etc/hostname"
    write_file "$TARGET/etc/hosts" <<EOF
127.0.0.1   localhost
::1         localhost
127.0.1.1   $HOSTNAME_NEW.localdomain $HOSTNAME_NEW
EOF
}

# The password goes through a pipe (printf is a shell builtin): never on a command line
# that ps could show, and never into the log.
set_password() {
    if $DRY_RUN; then echo "(password for $USERNAME) | arch-chroot $TARGET chpasswd"; return 0; fi
    echo "\$ (password for $USERNAME) | arch-chroot $TARGET chpasswd"
    printf '%s:%s\n' "$USERNAME" "$PASSWORD" | arch-chroot "$TARGET" chpasswd
}

target_name_in_use() {
    local matches
    matches=$(awk -F: -v name="$USERNAME" '$1 == name { print $1 }' \
        "$TARGET/etc/passwd" "$TARGET/etc/group") || die "Cannot check target account/group names"
    [[ -n $matches ]]
}

check_target_username() {
    $DRY_RUN && return 0
    while target_name_in_use; do
        ask_username "Installed packages already use account/group $USERNAME. Choose another username."
    done
}

create_user() {
    if ! $DRY_RUN && target_name_in_use; then
        die "Target account/group $USERNAME appeared before useradd; refusing to modify it"
    fi
    in_target useradd -m -G wheel -s /usr/bin/fish "$USERNAME"
    set_password
    in_target passwd -l root
    echo "%wheel ALL=(ALL:ALL) ALL" | write_file "$TARGET/etc/sudoers.d/10-wheel" 440
    in_target visudo -cf /etc/sudoers.d/10-wheel
}

tune_system() {
    # the overlay's pacman hook only fires on later Hyprland upgrades
    in_target setcap cap_sys_nice=ep /usr/bin/Hyprland
    # starship's init pre-generated: fish starts in ~4 ms instead of ~9
    x mkdir -p "$TARGET/etc/fish/conf.d"
    if $DRY_RUN; then
        echo "arch-chroot $TARGET starship init fish --print-full-init > $TARGET/etc/fish/conf.d/starship.fish"
    else
        echo "\$ starship init fish --print-full-init > /etc/fish/conf.d/starship.fish"
        arch-chroot "$TARGET" starship init fish --print-full-init >"$TARGET/etc/fish/conf.d/starship.fish"
    fi
}

build_initramfs() { in_target mkinitcpio -P; }

install_bootloader() {
    local grub=$TARGET/etc/default/grub
    in_target grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=Gilgamesh
    set_conf "$grub" GRUB_TIMEOUT 0
    set_conf "$grub" GRUB_TIMEOUT_STYLE hidden
    set_conf "$grub" GRUB_CMDLINE_LINUX_DEFAULT '"quiet loglevel=3 nowatchdog zswap.enabled=0"'
    set_conf "$grub" GRUB_DISTRIBUTOR '"Gilgamesh"'
    in_target grub-mkconfig -o /boot/grub/grub.cfg
}

enable_services() {
    in_target systemctl enable NetworkManager.service systemd-resolved.service \
        systemd-timesyncd.service ufw.service fstrim.timer rtkit-daemon.service ly@tty2.service
    in_target systemctl disable getty@tty2.service
    # `ufw enable` needs a running kernel firewall, so switch it on for the next boot instead
    set_conf "$TARGET/etc/ufw/ufw.conf" ENABLED yes
}

hypr_local() {
    echo "-- Written by the Gilgamesh installer (your keyboard layout). Your own changes go here too."
    echo "hl.config({"
    echo "    input = {"
    echo "        kb_layout = \"$KB_LAYOUT\","
    if [[ -n $KB_OPTIONS ]]; then echo "        kb_options = \"$KB_OPTIONS\","; fi
    echo "    },"
    echo "})"
}

user_config() {
    local cfg=$TARGET/home/$USERNAME/.config
    x mkdir -p "$cfg/hypr" "$cfg/fish/conf.d" "$cfg/foot" "$cfg/mpv"
    x cp -r "$SRC/quickshell" "$cfg/quickshell"
    x cp "$SRC/hypr/hyprland.lua" "$cfg/hypr/hyprland.lua"
    hypr_local | write_file "$cfg/hypr/local.lua"
    x cp "$SRC/fish/colors.fish" "$SRC/fish/prompt.fish" "$cfg/fish/conf.d/"
    x cp "$SRC/fish/starship.toml" "$cfg/starship.toml"
    # the colors come from the bar's current theme
    write_file "$cfg/foot/foot.ini" <<'EOF'
include=~/.local/state/gilgamesh/theme/foot.ini
font=JetBrainsMono Nerd Font:size=12
EOF
    echo "hwdec=auto-safe" | write_file "$cfg/mpv/mpv.conf"
    in_target chown -R "$USERNAME:" "/home/$USERNAME"
}

# arch-chroot bind-mounts the live resolv.conf over the target's, so link it after the last chroot
link_resolv_conf() { x ln -sf ../run/systemd/resolve/stub-resolv.conf "$TARGET/etc/resolv.conf"; }

run_install() {
    ESP_PART=$(part 1) ROOT_PART=$(part 2)
    screen "Installing Gilgamesh on $DISK"
    if ! $DRY_RUN; then
        {
            echo "Gilgamesh install, $(date)"
            echo "disk=$DISK esp=$ESP_PART root=$ROOT_PART kernel=$KERNEL nvidia=$NVIDIA"
            echo "user=$USERNAME host=$HOSTNAME_NEW tz=$TIMEZONE xkb=$KB_LAYOUT/$KB_OPTIONS keymap=$KB_KEYMAP"
        } >"$LOG"
        LOG_STARTED=true
        MOUNT_JOURNAL=$(mktemp /tmp/gilgamesh-mounts.XXXXXX)
        UUID_FILE=$(mktemp /tmp/gilgamesh-uuids.XXXXXX)
        WRITE_MARKER=$(mktemp /tmp/gilgamesh-writes.XXXXXX)
    fi
    step "Partitioning $DISK" partition_disk
    if ! $DRY_RUN; then INSTALL_STATE=installing; fi
    step "Creating filesystems" make_filesystems
    if ! $DRY_RUN; then read -r ROOT_UUID ESP_UUID <"$UUID_FILE"; fi
    step "Mounting" mount_target
    step "Installing packages (takes a while)" install_packages
    step "pacman and fstab" base_config
    step "System files" copy_overlay
    step "Timezone, locale, keyboard, hostname" system_config
    CURRENT_STEP="Checking target username"
    check_target_username
    step "User $USERNAME" create_user
    step "Hyprland priority, fish prompt" tune_system
    step "Initramfs" build_initramfs
    step "Bootloader" install_bootloader
    step "Services and firewall" enable_services
    step "Desktop config for $USERNAME" user_config
    step "DNS" link_resolv_conf
    if $DRY_RUN; then INSTALL_STATE=dry-done; else INSTALL_STATE=installed; fi
    PASSWORD=""
}

done_screen() {
    CURRENT_STEP="Reboot prompt"
    echo
    if $DRY_RUN; then
        say --foreground "$GREEN" --bold "Dry run complete. Nothing was changed."
        return
    fi
    say --foreground "$GREEN" --bold "Gilgamesh is installed."
    say "Remove the installation medium (USB stick or ISO), then reboot."
    echo
    if confirm --affirmative "Reboot" --negative "Not yet" "Reboot now?"; then
        sync
        cleanup_mounts || die "Unmount failed; refusing to reboot"
        reboot
    else
        say "The installer will unmount its filesystems. Reboot when you're ready."
        echo
    fi
}

questions
run_install
done_screen

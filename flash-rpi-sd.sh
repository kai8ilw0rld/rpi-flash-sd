#!/usr/bin/env bash
# ==============================================================================
# Raspberry Pi OS MicroSD Flasher & Headless Provisioner
#
# Features:
#   1. Safely writes Raspberry Pi OS (.img or .img.xz) to a MicroSD card with dd.
#   2. Headless provisioning:
#      - SSH enabled on first boot (ssh file on the boot partition)
#      - User account (userconf.txt, SHA-512 crypt hash; default user: pi)
#      - Optional SSH public key for that user
#      - Hostname (/etc/hostname and /etc/hosts)
#      - Locale en_US.UTF-8 and Wi-Fi country US (fixed, compiled on first boot)
#      - Wi-Fi pre-configuration (NetworkManager profile, or wpa_supplicant.conf
#        on legacy images that do not ship NetworkManager)
#      - Optional file(s)/folder(s) copied into /home/<user>/ on first boot,
#        with correct ownership and permissions preserved
#   3. Drive safety checks so system and non-removable disks are not offered.
#
# Usage: sudo ./rpi-flash.sh [--show-all] [-h|--help]
#   --show-all   also list non-removable, non-system disks (use with care)
#
# WARNING: this script ERASES the disk you select. Double-check the device.
# ==============================================================================

set -o pipefail

readonly LOCALE="en_US.UTF-8"
readonly WIFI_COUNTRY="US"

SHOW_ALL=0
MOUNT_DIRS=()
BOOT_MNT=""
ROOT_MNT=""

# ------------------------------------------------------------------------------
# Helpers
# ------------------------------------------------------------------------------
die()  { echo "Error: $*" >&2; exit 1; }
warn() { echo "[!] $*" >&2; }

usage() {
    cat <<EOF
Usage: sudo ${0##*/} [--show-all] [-h|--help]

  --show-all   Also list non-removable, non-system disks (use with care)
  -h, --help   Show this help
EOF
}

# ask_yn "Question?" Y|N  -> returns 0 for yes, 1 for no
ask_yn() {
    local prompt=$1 def=${2:-N} hint ans
    [[ $def == Y ]] && hint="[Y/n]" || hint="[y/N]"
    read -r -p "$prompt $hint: " ans
    ans=${ans:-$def}
    [[ $ans =~ ^[Yy]$ ]]
}

human_bytes() {
    numfmt --to=iec "$1" 2>/dev/null || echo "$1 bytes"
}

cleanup() {
    local rc=$? d
    for d in "${MOUNT_DIRS[@]}"; do
        if mountpoint -q "$d" 2>/dev/null; then
            umount "$d" 2>/dev/null || umount -l "$d" 2>/dev/null
        fi
        rmdir "$d" 2>/dev/null
    done
    exit "$rc"
}
trap cleanup EXIT
trap 'echo; echo "Interrupted."; exit 130' INT TERM

# All mountpoints of a disk and its partitions/children (LVM, crypt, ...)
disk_mountpoints() {
    local node
    while IFS= read -r node; do
        findmnt -rn -o TARGET -S "$node" 2>/dev/null
    done < <(lsblk -lnpo NAME "$1" 2>/dev/null)
}

# True if the disk (or a child) carries a system mount or active swap
is_system_disk() {
    local mp node
    while IFS= read -r mp; do
        case $mp in
            /|/boot|/boot/*|/efi|/efi/*|/home|/home/*|/usr|/usr/*|/var|/var/*|/etc|/etc/*)
                return 0 ;;
        esac
    done < <(disk_mountpoints "$1")
    while IFS= read -r node; do
        if swapon --noheadings --show=NAME 2>/dev/null | grep -Fxq "$node"; then
            return 0
        fi
    done < <(lsblk -lnpo NAME "$1" 2>/dev/null)
    return 1
}

# True if the file at $2 lives on disk $1 (so we never flash over our own image)
disk_holds_path() {
    local src
    src=$(findmnt -nvo SOURCE -T "$2" 2>/dev/null)
    src=${src%%\[*}
    [[ -n $src ]] && lsblk -lnpo NAME "$1" 2>/dev/null | grep -Fxq "$src"
}

unmount_disk() {
    local node target
    while IFS= read -r node; do
        while IFS= read -r target; do
            [[ -n $target ]] && umount "$target" 2>/dev/null
        done < <(findmnt -rn -o TARGET -S "$node" 2>/dev/null)
    done < <(lsblk -lnpo NAME "$1" 2>/dev/null)
}

# Prints "device|size|transport|model" for each candidate disk
list_candidate_disks() {
    local dev type bytes removable tran size model
    while IFS= read -r dev; do
        [[ $dev == /dev/zram* || $dev == /dev/ram* ]] && continue
        type=$(lsblk -dno TYPE "$dev" 2>/dev/null | tr -d ' ')
        [[ $type == disk ]] || continue
        bytes=$(lsblk -bdno SIZE "$dev" 2>/dev/null | tr -d ' ')
        [[ ${bytes:-0} -gt 0 ]] || continue          # empty card-reader slot
        is_system_disk "$dev" && continue
        disk_holds_path "$dev" "$SELECTED_IMAGE" && continue

        removable=$(lsblk -dno RM "$dev" 2>/dev/null | tr -d ' ')
        tran=$(lsblk -dno TRAN "$dev" 2>/dev/null | tr -d ' ')
        if (( SHOW_ALL == 0 )) && [[ $removable != 1 && $tran != usb && $dev != /dev/mmcblk* ]]; then
            continue
        fi

        size=$(lsblk -dno SIZE "$dev" 2>/dev/null | tr -d ' ')
        model=$(lsblk -dno MODEL "$dev" 2>/dev/null | sed 's/^ *//; s/ *$//')
        printf '%s|%s|%s|%s\n' "$dev" "$size" "${tran:-?}" "${model:-unknown}"
    done < <(lsblk -dnpo NAME -e 7,11 2>/dev/null)
}

# Sets BOOT_PART (first vfat) and ROOT_PART (first ext4) on $TARGET_DISK
find_partitions() {
    local p fs
    BOOT_PART=""
    ROOT_PART=""
    while IFS= read -r p; do
        fs=$(lsblk -dno FSTYPE "$p" 2>/dev/null | tr -d ' ')
        [[ -z $BOOT_PART && $fs == vfat ]] && BOOT_PART=$p
        [[ -z $ROOT_PART && $fs == ext4 ]] && ROOT_PART=$p
    done < <(lsblk -lnpo NAME,TYPE "$TARGET_DISK" | awk '$2=="part"{print $1}')
}

mount_retry() {
    local part=$1 dir=$2 attempt
    for attempt in 1 2 3; do
        mount "$part" "$dir" 2>/dev/null && return 0
        warn "Mounting $part failed (attempt $attempt/3); retrying..."
        sleep 2
    done
    return 1
}

# Escape a value for NetworkManager keyfile (GKeyFile) strings
kf_escape() {
    local s=${1//\\/\\\\}
    printf '%s' "$s"
}

valid_psk() { [[ -z $1 ]] || { (( ${#1} >= 8 && ${#1} <= 63 )); }; }

# ------------------------------------------------------------------------------
# Argument parsing & preflight
# ------------------------------------------------------------------------------
for arg in "$@"; do
    case $arg in
        --show-all) SHOW_ALL=1 ;;
        -h|--help)  usage; exit 0 ;;
        *)          usage >&2; exit 2 ;;
    esac
done

if [[ $EUID -ne 0 ]]; then
    echo "Error: This script requires administrative privileges."
    echo "Please run with sudo: sudo $0"
    exit 1
fi

for cmd in dd lsblk findmnt mountpoint mount umount partprobe openssl stat \
           awk find sort realpath getent mktemp od swapon; do
    command -v "$cmd" &>/dev/null || die "Required command '$cmd' is not installed."
done

echo "=========================================================="
echo "  Raspberry Pi OS MicroSD Flasher & Headless Provisioner  "
echo "=========================================================="

TARGET_USER="${SUDO_USER:-$USER}"
USER_HOME=$(getent passwd "$TARGET_USER" | cut -d: -f6)
[[ -n $USER_HOME ]] || USER_HOME=$HOME
DOWNLOADS_DIR="$USER_HOME/Downloads"

# ------------------------------------------------------------------------------
# 1. Select image file
# ------------------------------------------------------------------------------
echo
echo "--- [Step 1/5] Select Raspberry Pi OS Image ---"

prompt_image_path() {
    local p
    while true; do
        read -r -e -p "Enter full path to .img or .img.xz file: " p
        p=${p/#\~/$USER_HOME}
        if [[ -f $p && $p =~ \.img(\.xz)?$ ]]; then
            SELECTED_IMAGE=$(realpath "$p")
            return
        fi
        warn "Not a readable .img or .img.xz file: $p"
    done
}

FOUND_IMAGES=()
if [[ -d $DOWNLOADS_DIR ]]; then
    while IFS= read -r -d '' f; do
        FOUND_IMAGES+=("$f")
    done < <(find "$DOWNLOADS_DIR" -maxdepth 2 -type f \( -name '*.img' -o -name '*.img.xz' \) -print0 2>/dev/null | sort -z)
fi

SELECTED_IMAGE=""
n=${#FOUND_IMAGES[@]}
if (( n > 0 )); then
    echo "Found image(s) in $DOWNLOADS_DIR:"
    for i in "${!FOUND_IMAGES[@]}"; do
        echo "  $((i + 1))) $(basename "${FOUND_IMAGES[$i]}")"
    done
    echo "  $((n + 1))) Specify another path..."

    while [[ -z $SELECTED_IMAGE ]]; do
        read -r -p "Select an option [1-$((n + 1))]: " img_choice
        if [[ $img_choice =~ ^[0-9]+$ ]] && (( 10#$img_choice >= 1 && 10#$img_choice <= n )); then
            SELECTED_IMAGE=${FOUND_IMAGES[10#$img_choice - 1]}
        elif [[ $img_choice =~ ^[0-9]+$ ]] && (( 10#$img_choice == n + 1 )); then
            prompt_image_path
        else
            warn "Invalid selection."
        fi
    done
else
    prompt_image_path
fi

if [[ $SELECTED_IMAGE == *.xz ]]; then
    for cmd in xz xzcat; do
        command -v "$cmd" &>/dev/null || die "Required command '$cmd' is not installed (needed for .xz images)."
    done
    IMAGE_BYTES=$(xz --robot --list "$SELECTED_IMAGE" 2>/dev/null | awk '$1=="totals"{print $5}')
else
    IMAGE_BYTES=$(stat -c %s "$SELECTED_IMAGE")
fi
[[ $IMAGE_BYTES =~ ^[0-9]+$ ]] || IMAGE_BYTES=0

echo "[+] Selected image: $SELECTED_IMAGE"

# ------------------------------------------------------------------------------
# 2. Select target MicroSD card
# ------------------------------------------------------------------------------
echo
echo "--- [Step 2/5] Select Target MicroSD Card ---"

AVAILABLE_DISKS=()
while IFS= read -r line; do
    [[ -n $line ]] && AVAILABLE_DISKS+=("$line")
done < <(list_candidate_disks)

if (( ${#AVAILABLE_DISKS[@]} == 0 )); then
    echo "[!] No safe, removable drives detected."
    echo "    Plug in your MicroSD card and re-run the script."
    echo "    (Use --show-all to list non-removable, non-system disks.)"
    exit 1
fi

echo "Available drives:"
for i in "${!AVAILABLE_DISKS[@]}"; do
    IFS='|' read -r dev size tran model <<< "${AVAILABLE_DISKS[$i]}"
    echo "  $((i + 1))) $dev  (Size: $size, Transport: $tran, Model: $model)"
done

TARGET_DISK=""
while [[ -z $TARGET_DISK ]]; do
    read -r -p "Select drive to flash [1-${#AVAILABLE_DISKS[@]}]: " disk_choice
    if [[ $disk_choice =~ ^[0-9]+$ ]] && (( 10#$disk_choice >= 1 && 10#$disk_choice <= ${#AVAILABLE_DISKS[@]} )); then
        IFS='|' read -r TARGET_DISK disk_size disk_tran disk_model <<< "${AVAILABLE_DISKS[10#$disk_choice - 1]}"
    else
        warn "Invalid selection."
    fi
done

[[ -b $TARGET_DISK ]] || die "$TARGET_DISK is not a block device."
DISK_BYTES=$(lsblk -bdno SIZE "$TARGET_DISK" | tr -d ' ')
if (( IMAGE_BYTES > 0 && IMAGE_BYTES > DISK_BYTES )); then
    die "Image ($(human_bytes "$IMAGE_BYTES")) is larger than $TARGET_DISK ($(human_bytes "$DISK_BYTES"))."
fi
echo "[+] Target drive: $TARGET_DISK ($disk_size)"

# ------------------------------------------------------------------------------
# 3. Headless provisioning questions (collected upfront, nothing is written yet)
# ------------------------------------------------------------------------------
echo
echo "--- [Step 3/5] Headless Configuration Settings ---"
echo "[+] SSH will be enabled."
echo "[+] Locale: $LOCALE   Wi-Fi country: $WIFI_COUNTRY (fixed)"

# --- User account -------------------------------------------------------------
CREATE_USER=0
RPI_USER="pi"
PASS_HASH=""
if ask_yn "Create a user account on first boot?" Y; then
    CREATE_USER=1
    while true; do
        read -r -p "Enter username [default: pi]: " user_input
        RPI_USER=${user_input:-pi}
        if [[ $RPI_USER =~ ^[a-z_][a-z0-9_-]{0,31}$ && $RPI_USER != root ]]; then
            break
        fi
        warn "Invalid username (lowercase letters, digits, '_' or '-', max 32 chars, not 'root')."
    done

    while true; do
        read -r -s -p "Enter password for '$RPI_USER': " RPI_PASS
        echo
        read -r -s -p "Confirm password: " RPI_PASS_CONFIRM
        echo
        if [[ -z $RPI_PASS ]]; then
            warn "Password cannot be empty."
        elif [[ $RPI_PASS != "$RPI_PASS_CONFIRM" ]]; then
            warn "Passwords do not match. Try again."
        else
            break
        fi
    done

    # Hash via stdin so the password never appears in the process list
    PASS_HASH=$(printf '%s' "$RPI_PASS" | openssl passwd -6 -stdin)
    unset RPI_PASS RPI_PASS_CONFIRM
    [[ $PASS_HASH == '$6$'* ]] || die "Failed to hash the password with openssl."
else
    warn "Without a user account you will not be able to log in over SSH."
    warn "You would need a monitor and keyboard for the first-boot setup wizard."
    ask_yn "Continue without creating a user account?" N || { echo "Cancelled."; exit 1; }
fi

# --- Hostname -----------------------------------------------------------------
read -r -p "Set hostname [default: raspberrypi]: " host_input
RPI_HOSTNAME=$(printf '%s' "${host_input:-raspberrypi}" \
    | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9-' | sed -E 's/^-+//; s/-+$//' | cut -c1-63)
if [[ -z $RPI_HOSTNAME ]]; then
    RPI_HOSTNAME="raspberrypi"
fi
if [[ -n $host_input && $host_input != "$RPI_HOSTNAME" ]]; then
    warn "Hostname adjusted to a valid form."
fi
echo "[+] Hostname will be set to: $RPI_HOSTNAME"

# --- Wi-Fi --------------------------------------------------------------------
WIFI_SSIDS=()
WIFI_PSKS=()
if ask_yn "Pre-configure Wi-Fi for first boot?" N; then
    while true; do
        read -r -p "Enter Wi-Fi SSID: " net_ssid
        if [[ -z $net_ssid ]]; then
            warn "SSID cannot be empty."
            continue
        fi
        if (( $(printf '%s' "$net_ssid" | wc -c) > 32 )); then
            warn "SSID cannot be longer than 32 bytes."
            continue
        fi
        read -r -s -p "Enter Wi-Fi password for '$net_ssid' (empty if open network): " net_pass
        echo
        if ! valid_psk "$net_pass"; then
            warn "WPA passwords must be 8-63 characters."
            continue
        fi
        WIFI_SSIDS+=("$net_ssid")
        WIFI_PSKS+=("$net_pass")
        echo "[+] Added Wi-Fi network: $net_ssid"
        ask_yn "Add another Wi-Fi network?" N || break
    done
fi

# --- SSH public key & custom files (only meaningful with a user account) ------
SSH_PUBKEY=""
INJECT_FILES=()
if (( CREATE_USER )); then
    if ask_yn "Install an SSH public key for '$RPI_USER'?" N; then
        default_key=""
        for k in "$USER_HOME/.ssh/id_ed25519.pub" "$USER_HOME/.ssh/id_ecdsa.pub" "$USER_HOME/.ssh/id_rsa.pub"; do
            if [[ -f $k ]]; then default_key=$k; break; fi
        done
        while true; do
            read -r -e -p "Path to public key [${default_key:-none}]: " key_input
            key_input=${key_input:-$default_key}
            key_input=${key_input/#\~/$USER_HOME}
            if [[ -z $key_input ]]; then
                warn "No key selected; skipping."
                break
            elif [[ -f $key_input ]] && grep -Eq '^(ssh-|ecdsa-|sk-)' "$key_input"; then
                SSH_PUBKEY=$(realpath "$key_input")
                echo "[+] Will install public key: $SSH_PUBKEY"
                break
            else
                warn "Not a valid public key file: $key_input (leave empty to skip)"
                default_key=""
            fi
        done
    fi

    if ask_yn "Include file(s) in the user's home folder (/home/$RPI_USER)?" N; then
        while true; do
            read -r -e -p "Enter path to file or folder to include: " custom_file
            custom_file=${custom_file/#\~/$USER_HOME}
            if [[ -e $custom_file ]]; then
                INJECT_FILES+=("$(realpath "$custom_file")")
                echo "[+] Queued: $custom_file"
            else
                warn "Path does not exist: $custom_file"
            fi
            ask_yn "Include another file?" N || break
        done
    fi
fi

# ------------------------------------------------------------------------------
# Final confirmation
# ------------------------------------------------------------------------------
echo
echo "Summary:"
echo "  Image:    $(basename "$SELECTED_IMAGE")"
echo "  Target:   $TARGET_DISK ($disk_size, $disk_model)"
echo
lsblk -o NAME,SIZE,FSTYPE,LABEL,MOUNTPOINT "$TARGET_DISK"
echo
echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
echo "  WARNING: ALL DATA ON $TARGET_DISK ($disk_size) WILL BE DESTROYED!"
echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
read -r -p "Type the device path ($TARGET_DISK) to confirm: " confirm_dev
if [[ $confirm_dev != "$TARGET_DISK" ]]; then
    echo "Operation cancelled. Nothing was written."
    exit 1
fi

# ------------------------------------------------------------------------------
# 4. Flash image with dd
# ------------------------------------------------------------------------------
echo
echo "--- [Step 4/5] Flashing Image to $TARGET_DISK ---"

# Re-check right before writing
[[ -b $TARGET_DISK ]] || die "$TARGET_DISK is not a block device."
is_system_disk "$TARGET_DISK" && die "Refusing to write: $TARGET_DISK carries system mounts."
disk_holds_path "$TARGET_DISK" "$SELECTED_IMAGE" && die "The image file is stored on $TARGET_DISK."

echo "Unmounting any existing partitions on $TARGET_DISK..."
unmount_disk "$TARGET_DISK"
[[ -z $(disk_mountpoints "$TARGET_DISK") ]] || die "Could not unmount all partitions on $TARGET_DISK."

echo "Writing image to $TARGET_DISK (this may take a few minutes)..."
if [[ $SELECTED_IMAGE == *.xz ]]; then
    xzcat -- "$SELECTED_IMAGE" | dd of="$TARGET_DISK" bs=4M iflag=fullblock conv=fsync status=progress
else
    dd if="$SELECTED_IMAGE" of="$TARGET_DISK" bs=4M conv=fsync status=progress
fi
flash_rc=$?
(( flash_rc == 0 )) || die "Flashing failed (exit code $flash_rc). The card contents are not usable."

echo "Flushing disk write buffers..."
sync
echo "[+] Flashing complete!"

# ------------------------------------------------------------------------------
# 5. Provision boot and root partitions
# ------------------------------------------------------------------------------
echo
echo "--- [Step 5/5] Applying Headless Configuration ---"
echo "Reloading partition table..."
partprobe "$TARGET_DISK" 2>/dev/null
if command -v udevadm &>/dev/null; then udevadm settle 2>/dev/null; else sleep 3; fi

for _ in {1..20}; do
    find_partitions
    [[ -n $BOOT_PART && -n $ROOT_PART ]] && break
    sleep 1
done
[[ -n $BOOT_PART ]] || die "Could not find the boot (vfat) partition on $TARGET_DISK."
[[ -n $ROOT_PART ]] || die "Could not find the root (ext4) partition on $TARGET_DISK."

# A desktop automounter may have mounted the fresh partitions already
unmount_disk "$TARGET_DISK"

BOOT_MNT=$(mktemp -d /tmp/rpi-boot-XXXXXX) || die "mktemp failed."
MOUNT_DIRS+=("$BOOT_MNT")
ROOT_MNT=$(mktemp -d /tmp/rpi-root-XXXXXX) || die "mktemp failed."
MOUNT_DIRS+=("$ROOT_MNT")

echo "[+] Mounting boot partition ($BOOT_PART) and rootfs ($ROOT_PART)..."
mount_retry "$BOOT_PART" "$BOOT_MNT" || die "Could not mount boot partition $BOOT_PART."
mount_retry "$ROOT_PART" "$ROOT_MNT" || die "Could not mount root partition $ROOT_PART."
[[ -d $ROOT_MNT/etc && -d $ROOT_MNT/usr ]] || die "$ROOT_PART does not look like a Linux root filesystem."

# --- Boot partition: SSH + user ----------------------------------------------
touch "$BOOT_MNT/ssh"
echo "[+] Enabled SSH (ssh file created)"

if (( CREATE_USER )); then
    # Note: the boot partition is FAT, so file permissions cannot be enforced.
    printf '%s:%s\n' "$RPI_USER" "$PASS_HASH" > "$BOOT_MNT/userconf.txt"
    echo "[+] Created user '$RPI_USER' (userconf.txt created)"
fi
unset PASS_HASH

# --- Rootfs: locale -----------------------------------------------------------
mkdir -p "$ROOT_MNT/etc/default"
printf 'LANG=%s\n' "$LOCALE" > "$ROOT_MNT/etc/default/locale"
if [[ -f $ROOT_MNT/etc/locale.gen ]]; then
    sed -i 's/^# *en_US\.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' "$ROOT_MNT/etc/locale.gen"
    grep -qx 'en_US.UTF-8 UTF-8' "$ROOT_MNT/etc/locale.gen" \
        || echo 'en_US.UTF-8 UTF-8' >> "$ROOT_MNT/etc/locale.gen"
fi
echo "[+] Default locale set to $LOCALE"

# --- Rootfs: hostname ---------------------------------------------------------
printf '%s\n' "$RPI_HOSTNAME" > "$ROOT_MNT/etc/hostname"
if [[ -f $ROOT_MNT/etc/hosts ]]; then
    if grep -q '^127\.0\.1\.1' "$ROOT_MNT/etc/hosts"; then
        sed -i -E "s/^127\.0\.1\.1.*/127.0.1.1\t$RPI_HOSTNAME/" "$ROOT_MNT/etc/hosts"
    else
        printf '127.0.1.1\t%s\n' "$RPI_HOSTNAME" >> "$ROOT_MNT/etc/hosts"
    fi
fi
echo "[+] Hostname set to '$RPI_HOSTNAME'"

# --- Wi-Fi --------------------------------------------------------------------
WIFI_METHOD=""
if (( ${#WIFI_SSIDS[@]} > 0 )); then
    if [[ -x $ROOT_MNT/usr/sbin/NetworkManager ]]; then
        WIFI_METHOD="NetworkManager"
        NM_DIR="$ROOT_MNT/etc/NetworkManager/system-connections"
        mkdir -p "$NM_DIR"
        for i in "${!WIFI_SSIDS[@]}"; do
            ssid=${WIFI_SSIDS[$i]}
            psk=${WIFI_PSKS[$i]}
            safe=${ssid//[^A-Za-z0-9._-]/_}
            nm_file="$NM_DIR/wifi-$((i + 1))-${safe:0:40}.nmconnection"
            {
                printf '[connection]\nid=%s\nuuid=%s\ntype=wifi\nautoconnect=true\n\n' \
                    "$(kf_escape "$ssid")" "$(cat /proc/sys/kernel/random/uuid)"
                printf '[wifi]\nmode=infrastructure\nssid=%s\n\n' "$(kf_escape "$ssid")"
                if [[ -n $psk ]]; then
                    printf '[wifi-security]\nkey-mgmt=wpa-psk\npsk=%s\n\n' "$(kf_escape "$psk")"
                fi
                printf '[ipv4]\nmethod=auto\n\n[ipv6]\nmethod=auto\n'
            } > "$nm_file"
            chmod 600 "$nm_file"
            chown 0:0 "$nm_file" 2>/dev/null
            echo "[+] Configured NetworkManager profile for '$ssid'"
        done
    else
        # Legacy image (no NetworkManager): wpa_supplicant.conf on the boot partition.
        # Raspberry Pi OS moves it into place on first boot.
        WIFI_METHOD="wpa_supplicant (legacy)"
        {
            printf 'ctrl_interface=DIR=/var/run/wpa_supplicant GROUP=netdev\nupdate_config=1\ncountry=%s\n' "$WIFI_COUNTRY"
            for i in "${!WIFI_SSIDS[@]}"; do
                ssid_hex=$(printf '%s' "${WIFI_SSIDS[$i]}" | od -An -tx1 | tr -d ' \n')
                printf '\nnetwork={\n    ssid=%s\n' "$ssid_hex"
                if [[ -n ${WIFI_PSKS[$i]} ]]; then
                    printf '    psk="%s"\n' "${WIFI_PSKS[$i]}"
                else
                    printf '    key_mgmt=NONE\n'
                fi
                printf '}\n'
            done
        } > "$BOOT_MNT/wpa_supplicant.conf"
        echo "[+] Configured legacy wpa_supplicant.conf for ${#WIFI_SSIDS[@]} network(s)"
    fi
fi

# --- Staging area for first-boot service --------------------------------------
FB_DIR="$ROOT_MNT/usr/local/share/rpi-firstboot"
FB_HOME="$FB_DIR/home"
mkdir -p "$FB_HOME" "$ROOT_MNT/usr/local/sbin" "$ROOT_MNT/etc/systemd/system/multi-user.target.wants"

{
    printf 'RPI_USER=%q\n' "$RPI_USER"
    printf 'LOCALE=%q\n' "$LOCALE"
    printf 'WIFI_COUNTRY=%q\n' "$WIFI_COUNTRY"
} > "$FB_DIR/config"

for item in "${INJECT_FILES[@]}"; do
    echo "[+] Staging $(basename "$item") for /home/$RPI_USER..."
    cp -a -- "$item" "$FB_HOME/" || die "Failed to copy $item"
done

if [[ -n $SSH_PUBKEY ]]; then
    install -d -m 700 "$FB_HOME/.ssh"
    cat -- "$SSH_PUBKEY" >> "$FB_HOME/.ssh/authorized_keys"
    chmod 600 "$FB_HOME/.ssh/authorized_keys"
    echo "[+] Staged SSH public key for '$RPI_USER'"
fi

# --- First-boot service -------------------------------------------------------
cat > "$ROOT_MNT/etc/systemd/system/rpi-firstboot.service" <<'UNIT_EOF'
[Unit]
Description=Raspberry Pi first-boot provisioning (locale, Wi-Fi country, user files)
After=local-fs.target userconfig.service NetworkManager.service

[Service]
Type=oneshot
ExecStart=/bin/bash /usr/local/sbin/rpi-firstboot.sh
TimeoutStartSec=180
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
UNIT_EOF

cat > "$ROOT_MNT/usr/local/sbin/rpi-firstboot.sh" <<'FIRSTBOOT_EOF'
#!/bin/bash
# Generated by rpi-flash.sh. Runs as root on first boot.
# Safe to re-run: the service removes itself only after files were deployed.

BASE=/usr/local/share/rpi-firstboot
STAGE="$BASE/home"
# shellcheck disable=SC1091
[ -f "$BASE/config" ] && . "$BASE/config"
: "${RPI_USER:=pi}" "${LOCALE:=en_US.UTF-8}" "${WIFI_COUNTRY:=US}"

# 1. Compile locale
sed -i 's/^# *en_US\.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen
grep -qx 'en_US.UTF-8 UTF-8' /etc/locale.gen || echo 'en_US.UTF-8 UTF-8' >> /etc/locale.gen
locale-gen
update-locale LANG="$LOCALE"

# 2. Wi-Fi country and radio
command -v raspi-config >/dev/null 2>&1 && raspi-config nonint do_wifi_country "$WIFI_COUNTRY"
command -v rfkill >/dev/null 2>&1 && rfkill unblock wifi
if command -v nmcli >/dev/null 2>&1; then
    nmcli radio wifi on 2>/dev/null
    nmcli connection reload 2>/dev/null
fi

# 3. Deploy staged files into the user's home (wait for the account to exist)
deployed=1
if [ -n "$(ls -A "$STAGE" 2>/dev/null)" ]; then
    deployed=0
    for _ in $(seq 1 60); do
        if id -u "$RPI_USER" >/dev/null 2>&1 && [ -d "/home/$RPI_USER" ]; then
            break
        fi
        sleep 2
    done

    if id -u "$RPI_USER" >/dev/null 2>&1 && [ -d "/home/$RPI_USER" ]; then
        deployed=1
        while IFS= read -r -d '' entry; do
            name=$(basename "$entry")
            if ! { cp -a "$entry" "/home/$RPI_USER/" && chown -R "$RPI_USER:" "/home/$RPI_USER/$name"; }; then
                deployed=0
            fi
        done < <(find "$STAGE" -mindepth 1 -maxdepth 1 -print0)
    fi
fi

# 4. Clean up only after success; otherwise retry on the next boot
if [ "$deployed" = 1 ]; then
    rm -rf "$BASE"
    rm -f /etc/systemd/system/multi-user.target.wants/rpi-firstboot.service
    rm -f /etc/systemd/system/rpi-firstboot.service
    rm -f /usr/local/sbin/rpi-firstboot.sh
    exit 0
fi
echo "rpi-firstboot: could not deploy files yet; will retry on next boot" >&2
exit 1
FIRSTBOOT_EOF

chmod 755 "$ROOT_MNT/usr/local/sbin/rpi-firstboot.sh"
ln -sf /etc/systemd/system/rpi-firstboot.service \
    "$ROOT_MNT/etc/systemd/system/multi-user.target.wants/rpi-firstboot.service"
echo "[+] Installed first-boot service (locale, Wi-Fi country, file deployment)"

# --- Finish -------------------------------------------------------------------
echo "Flushing final filesystem sync..."
sync
umount "$BOOT_MNT" || die "Failed to unmount $BOOT_MNT. Do NOT remove the card yet."
umount "$ROOT_MNT" || die "Failed to unmount $ROOT_MNT. Do NOT remove the card yet."
sync

echo
echo "=========================================================="
echo "  [SUCCESS] MicroSD Card is Ready to Boot!                "
echo "=========================================================="
echo "Image:     $(basename "$SELECTED_IMAGE")"
echo "Disk:      $TARGET_DISK"
echo "Hostname:  $RPI_HOSTNAME"
echo "Locale:    $LOCALE"
echo "SSH:       Enabled"
if (( CREATE_USER )); then
    echo "User:      $RPI_USER"
    [[ -n $SSH_PUBKEY ]] && echo "SSH key:   $(basename "$SSH_PUBKEY") installed"
fi
if (( ${#WIFI_SSIDS[@]} > 0 )); then
    echo "Wi-Fi:     $WIFI_METHOD, ${#WIFI_SSIDS[@]} network(s), Country: $WIFI_COUNTRY"
    for ssid in "${WIFI_SSIDS[@]}"; do
        echo "           - $ssid"
    done
fi
if (( ${#INJECT_FILES[@]} > 0 )); then
    echo "Files in ~/:"
    for f in "${INJECT_FILES[@]}"; do
        echo "           - $(basename "$f")"
    done
fi
echo
echo "Next Steps:"
echo "  1. Unplug the MicroSD card from this computer."
echo "  2. Insert it into your Raspberry Pi and plug in power."
echo "  3. Wait ~1-2 minutes for the initial first-boot expansion."
if (( CREATE_USER )); then
    echo "  4. Connect via SSH:"
    echo "     ssh $RPI_USER@$RPI_HOSTNAME.local"
fi
echo "=========================================================="
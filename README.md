# rpi-flash

An interactive Bash script that writes a Raspberry Pi OS image to a MicroSD card and pre-configures it for **headless** first boot: SSH, a user account, hostname, Wi-Fi, locale, and any files you want waiting in the home folder.

> ## ⚠️ Warning
> This script **erases the entire disk you select**. It has several safety checks (see [Safety features](#safety-features)), but you are responsible for choosing the right device. Read the device list and the final summary carefully before confirming.

## Features

- Flashes `.img` and `.img.xz` images with `dd` (with progress and a final `fsync`)
- **SSH** enabled on first boot
- **User account** created via `userconf.txt` (SHA-512 password hash, default username `pi`)
- Optional **SSH public key** installed for that user
- **Hostname** set in `/etc/hostname` and `/etc/hosts`
- **Locale** fixed to `en_US.UTF-8` and **Wi-Fi country** fixed to `US` (compiled/applied on first boot)
- **Wi-Fi pre-configuration** for one or more networks
  - NetworkManager profiles on modern images
  - `wpa_supplicant.conf` on legacy images that don't ship NetworkManager
- Optional **file/folder injection** into `/home/<user>/` with ownership and permissions handled on first boot
- Everything is asked up front; nothing is written to the card until you confirm

## Requirements

- Linux (uses `lsblk`, `findmnt`, `partprobe`, etc.; macOS and WSL are not supported)
- Root privileges (`sudo`)
- Bash 4+
- These commands: `dd`, `lsblk`, `findmnt`, `mountpoint`, `mount`, `umount`, `swapon`, `partprobe`, `openssl`, `stat`, `awk`, `find`, `sort`, `realpath`, `getent`, `mktemp`, `od`
- `xz` and `xzcat` for `.img.xz` images
- Optional: `udevadm` (faster partition settling), `numfmt` (human-readable sizes)

On Debian/Ubuntu-based systems:

```bash
sudo apt install util-linux parted openssl xz-utils coreutils
```

## Usage

```bash
chmod +x rpi-flash.sh
sudo ./rpi-flash.sh
```

Options:

| Option | Description |
| --- | --- |
| `--show-all` | Also list non-removable, non-system disks. Use with care. |
| `-h`, `--help` | Show usage. |

### Walkthrough

1. **Select the image.** Images found in `~/Downloads` (up to two levels deep) are listed, or you can enter a path.
2. **Select the target drive.** Only safe candidates are shown (see below).
3. **Answer the configuration questions.** User, hostname, Wi-Fi, SSH key, and files.
4. **Confirm.** Review the summary and type the device path (for example `/dev/sdb`) to proceed.
5. **Flash and provision.** The script writes the image, then mounts the boot and root partitions and applies your settings.

When it finishes, unplug the card, put it in the Pi, and power it on. After the first boot completes (about 1–2 minutes), connect with:

```bash
ssh <username>@<hostname>.local
```

## What gets configured

| Setting | How |
| --- | --- |
| SSH | Empty `ssh` file on the boot partition |
| User | `userconf.txt` on the boot partition (`user:hash`) |
| SSH key | Staged on the root partition, installed to `~/.ssh/authorized_keys` on first boot |
| Hostname | `/etc/hostname` and the `127.0.1.1` line in `/etc/hosts` |
| Locale | `/etc/default/locale`, `/etc/locale.gen`, and `locale-gen` on first boot |
| Wi-Fi country | `raspi-config nonint do_wifi_country US` on first boot, plus `rfkill unblock wifi` |
| Wi-Fi networks | `/etc/NetworkManager/system-connections/*.nmconnection`, or `wpa_supplicant.conf` on legacy images |
| Custom files | Staged under `/usr/local/share/rpi-firstboot/home`, copied into `/home/<user>/` on first boot |

A one-shot systemd service (`rpi-firstboot.service`) handles the first-boot steps. It waits for the user account to exist, deploys your files, and then removes itself. If the account never appears, it leaves your staged files in place and retries on the next boot.

## Safety features

- Only **removable, USB, or `mmcblk`** disks are listed by default
- Disks with **system mounts** (`/`, `/boot`, `/home`, `/usr`, `/var`, `/etc`, `/efi`) or active **swap** are never offered, including disks with LVM/crypt children
- **Empty card-reader slots** (0 bytes) and the disk holding the **image file** are excluded
- The image is checked against the disk size before anything is written
- The target is re-verified immediately before `dd` runs
- You must **type the device path** to confirm, not just "yes"
- `dd`/`xzcat` exit codes are checked, so a failed flash stops the script
- A cleanup trap unmounts and removes temporary directories on error or Ctrl-C

## Security notes

- Your password is hashed with `openssl passwd -6 -stdin`, so it never appears in the process list, and only the hash is written to the card.
- The boot partition is FAT, so **file permissions are not enforced there**. Anyone who mounts the card can read `userconf.txt` (the hash) and, on legacy images, `wpa_supplicant.conf`.
- Wi-Fi passwords are stored **in plaintext** in the NetworkManager profile on the card (mode `600`, owned by root, which is standard for NetworkManager). Treat the card accordingly.
- SSH is enabled with password authentication by default. Installing an SSH key is recommended; this script does not disable password login.

## Compatibility

Newer Raspberry Pi OS releases may use different first-boot mechanisms (for example cloud-init). If something doesn't apply on a newer image, please open an issue with the image name and version.

## Troubleshooting

**No drives detected.** Make sure the card is inserted and visible in `lsblk`. If your reader shows up as a non-removable device, try `--show-all`.

**Could not mount the boot or root partition.** Another program (such as a desktop automounter) may be using the card. Unmount it and run the script again.

**Can't connect over SSH.**
- Confirm the Pi has booted and joined your network (check your router for the hostname).
- Try the IP address instead of `<hostname>.local`.
- Wi-Fi passwords must be 8–63 characters; check for typos in the SSID.
- First boot can take a couple of minutes while the filesystem expands.

**Files didn't appear in the home folder.** The first-boot service waits up to about two minutes for the user account. If it timed out, reboot once so it can retry. Check with `systemctl status rpi-firstboot.service`.

## Contributing

Issues and pull requests are welcome. Please run [`shellcheck`](https://www.shellcheck.net/) on any changes and include the Raspberry Pi OS image you tested with.

## Disclaimer

This software is provided as is, without warranty of any kind. You are responsible for any data loss resulting from its use.

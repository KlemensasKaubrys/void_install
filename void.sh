#!/usr/bin/env bash
set -euo pipefail

DISK=""
EFI_SIZE="200MiB"
BOOT_SIZE="500MiB"
HOSTNAME="void-host"
ARCH="x86_64"
REPO="https://alpha.us.repo.voidlinux.org/current"
USE_MUSL="no"
FORCE="no"
LUKS_NAME="cryptroot"
BTRFS_LABEL="void"
EFI_LABEL="BOOT"
BOOT_LABEL="grub"
BTRFS_OPTS_DEFAULT="rw,noatime,ssd,compress=zstd,space_cache,commit=120"

die() { echo "ERROR: $*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"; }
yn() { read -rp "$1 [y/N]: " _a; [[ "${_a:-}" =~ ^[Yy]$ ]]; }
to_mib() {
  local s="${1^^}"
  if [[ "$s" =~ ^([0-9]+)MIB$ ]]; then echo "${BASH_REMATCH[1]}";
  elif [[ "$s" =~ ^([0-9]+)GIB$ ]]; then echo $(( ${BASH_REMATCH[1]} * 1024 ));
  elif [[ "$s" =~ ^([0-9]+)MB$ ]]; then awk -v n="${BASH_REMATCH[1]}" 'BEGIN{printf "%d", n*1000/1024}';
  elif [[ "$s" =~ ^([0-9]+)GB$ ]]; then echo $(( ${BASH_REMATCH[1]} * 1000 * 1000 / 1024 ));
  else die "Unsupported size: $1"; fi
}
wait_for() {
  local path="$1" tries=40; while ! [[ -e "$path" ]]; do sleep 0.1; tries=$((tries-1)); [[ $tries -le 0 ]] && die "Timed out waiting for $path"; done
}

usage() {
  cat <<EOF
Usage: $0 --disk /dev/sdX [options]
  --disk DEVICE
  --efi-size SIZE
  --boot-size SIZE
  --hostname NAME
  --arch x86_64|x86_64-musl
  --repo URL
  --musl yes|no
  --force
  --help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --disk) DISK="${2:-}"; shift 2 ;;
    --efi-size) EFI_SIZE="${2:-}"; shift 2 ;;
    --boot-size) BOOT_SIZE="${2:-}"; shift 2 ;;
    --hostname) HOSTNAME="${2:-}"; shift 2 ;;
    --arch) ARCH="${2:-}"; shift 2 ;;
    --repo) REPO="${2:-}"; shift 2 ;;
    --musl) USE_MUSL="${2:-}"; shift 2 ;;
    --force) FORCE="yes"; shift ;;
    --help|-h) usage; exit 0 ;;
    *) die "Unknown option: $1" ;;
  esac
done

[[ -b "${DISK:-}" ]] || { usage; die "--disk is required and must be a block device"; }
if [[ "$USE_MUSL" == "yes" ]]; then ARCH="x86_64-musl"; REPO="${REPO%/}/musl"; fi

for cmd in parted mkfs.vfat mkfs.ext2 cryptsetup mkfs.btrfs lsblk xbps-install chroot grub-install grub-mkconfig awk wipefs udevadm findmnt; do need "$cmd"; done
[[ -z "$(mount | grep -E "^${DISK}[p0-9]*")" ]] || die "Some partitions on $DISK are mounted; unmount them first."

EFI_MIB="$(to_mib "$EFI_SIZE")"
BOOT_MIB="$(to_mib "$BOOT_SIZE")"
START_EFI=1
END_EFI=$(( START_EFI + EFI_MIB ))
START_BOOT=$(( END_EFI + 1 ))
END_BOOT=$(( START_BOOT + BOOT_MIB ))

echo ">>> Planned actions on $DISK"
echo "    GPT: [1] EFI ${EFI_MIB}MiB  [2] /boot ${BOOT_MIB}MiB  [3] LUKS+btrfs root (rest)"
lsblk -dno NAME,SIZE,MODEL "$DISK" || true
if [[ "$FORCE" != "yes" ]]; then yn "This will destroy all data on $DISK. Continue?" || exit 1; fi

parted -s "$DISK" mklabel gpt
parted -s "$DISK" mkpart ESP fat32 "${START_EFI}MiB" "${END_EFI}MiB"
parted -s "$DISK" set 1 esp on
parted -s "$DISK" mkpart boot ext2 "${START_BOOT}MiB" "${END_BOOT}MiB"
parted -s "$DISK" mkpart root btrfs "${END_BOOT}MiB" 100%
udevadm settle

if [[ "$DISK" =~ nvme ]]; then P1="${DISK}p1"; P2="${DISK}p2"; P3="${DISK}p3"; else P1="${DISK}1"; P2="${DISK}2"; P3="${DISK}3"; fi

mkfs.vfat -n "$EFI_LABEL" -F32 "$P1"
mkfs.ext2 -L "$BOOT_LABEL" "$P2"

cryptsetup luksFormat --type luks2 -s 512 "$P3"
cryptsetup open "$P3" "$LUKS_NAME"
wait_for "/dev/mapper/${LUKS_NAME}"
udevadm settle
wipefs -a "/dev/mapper/${LUKS_NAME}" || true
mkfs.btrfs -f -L "$BTRFS_LABEL" "/dev/mapper/${LUKS_NAME}"

BTRFS_OPTS="${BTRFS_OPTS_DEFAULT}"

mount -o "$BTRFS_OPTS" "/dev/mapper/${LUKS_NAME}" /mnt
btrfs subvolume create /mnt/@
btrfs subvolume create /mnt/@home
btrfs subvolume create /mnt/@snapshots
umount /mnt

mount -o "${BTRFS_OPTS},subvol=@" "/dev/mapper/${LUKS_NAME}" /mnt
mkdir -p /mnt/home
mount -o "${BTRFS_OPTS},subvol=@home" "/dev/mapper/${LUKS_NAME}" /mnt/home
mkdir -p /mnt/.snapshots
mount -o "${BTRFS_OPTS},subvol=@snapshots" "/dev/mapper/${LUKS_NAME}" /mnt/.snapshots

mkdir -p /mnt/var/cache
btrfs subvolume create /mnt/var/cache/xbps
btrfs subvolume create /mnt/var/tmp
btrfs subvolume create /mnt/srv
btrfs subvolume create /mnt/var/swap

mkdir -p /mnt/efi
mount -o rw,noatime "$P1" /mnt/efi
mkdir -p /mnt/boot
mount -o rw,noatime "$P2" /mnt/boot

export XBPS_ARCH="$ARCH"
xbps-install -S -R "$REPO" -r /mnt base-system btrfs-progs cryptsetup e2fsprogs util-linux

for dir in dev proc sys run; do mount --rbind "/$dir" "/mnt/$dir"; mount --make-rslave "/mnt/$dir"; done
cp -f /etc/resolv.conf /mnt/etc/resolv.conf

cat >/mnt/root/post-chroot.sh <<'CHROOT_SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
: "${HOSTNAME:?}"; : "${BTRFS_OPTS:?}"; : "${EFI_PART:?}"; : "${BOOT_PART:?}"; : "${LUKS_NAME:?}"

echo "${HOSTNAME}" >/etc/hostname
if [[ ! -f /etc/rc.conf ]]; then
  cat >/etc/rc.conf <<EOF
HARDWARECLOCK="UTC"
TIMEZONE="UTC"
KEYMAP="us"
FONT=""
HARDWAREPROFILE="yes"
EOF
fi

if xbps-query -Rs '^glibc-locales$' >/dev/null 2>&1; then
  if [[ -f /etc/default/libc-locales ]]; then
    sed -i 's/^# \(en_US.UTF-8 UTF-8\)/\1/' /etc/default/libc-locales || true
    xbps-reconfigure -f glibc-locales || true
  fi
fi

passwd

UEFI_UUID=$(findmnt -no UUID /efi || true)
BOOT_UUID=$(findmnt -no UUID /boot || true)
ROOT_UUID=$(findmnt -no UUID / || true)

cat >/etc/fstab <<EOF
UUID=${ROOT_UUID} / btrfs ${BTRFS_OPTS},subvol=@ 0 1
UUID=${UEFI_UUID} /efi vfat defaults,noatime 0 2
UUID=${BOOT_UUID} /boot ext2 defaults,noatime 0 2
UUID=${ROOT_UUID} /home btrfs ${BTRFS_OPTS},subvol=@home 0 2
UUID=${ROOT_UUID} /.snapshots btrfs ${BTRFS_OPTS},subvol=@snapshots 0 2
tmpfs /tmp tmpfs defaults,nosuid,nodev 0 0
EOF

echo "hostonly=yes" >> /etc/dracut.conf

CPU_VENDOR=$(awk -F': ' '/vendor_id/ {print $2; exit}' /proc/cpuinfo || echo "")
if [[ "$CPU_VENDOR" == "GenuineIntel" ]]; then
  xbps-install -y void-repo-nonfree
  xbps-install -y intel-ucode
else
  xbps-install -y linux-firmware-amd || true
fi

xbps-install -y grub-x86_64-efi
grub-install --target=x86_64-efi --efi-directory=/efi --bootloader-id="Void Linux"

btrfs subvolume create /var/swap || true
truncate -s 0 /var/swap/swapfile
chattr +C /var/swap/swapfile || true
btrfs property set /var/swap/swapfile compression none || true
chmod 600 /var/swap/swapfile
dd if=/dev/zero of=/var/swap/swapfile bs=1G count=16 status=progress
mkswap /var/swap/swapfile
swapon /var/swap/swapfile

if btrfs inspect-internal map-swapfile -r /var/swap/swapfile >/tmp/resume 2>/dev/null; then
  RESUME_OFFSET="$(awk '/^file offset:/ {print $3}' /tmp/resume | head -n1)"
else
  RESUME_OFFSET="$(filefrag -v /var/swap/swapfile | awk '/^ *0:/{print $4}' | sed 's/\.\.//;s/[^0-9].*$//')"
fi

ROOT_UUID=$(findmnt -no UUID / || true)
sed -i '/^GRUB_CMDLINE_LINUX=/d' /etc/default/grub 2>/dev/null || true
if [[ -n "${RESUME_OFFSET:-}" && -n "${ROOT_UUID:-}" ]]; then
  echo "GRUB_CMDLINE_LINUX=\"resume=UUID=${ROOT_UUID} resume_offset=${RESUME_OFFSET}\"" >> /etc/default/grub
fi

xbps-install -y xorg-minimal mesa-dri xfce4 xfce4-terminal gdm dbus elogind polkit
ln -snf /etc/sv/dbus /var/service/dbus || true
ln -snf /etc/sv/elogind /var/service/elogind || true
ln -snf /etc/sv/gdm /var/service/gdm || true

xbps-reconfigure -fa
grub-mkconfig -o /boot/grub/grub.cfg
CHROOT_SCRIPT
chmod +x /mnt/root/post-chroot.sh

export HOSTNAME
export BTRFS_OPTS="${BTRFS_OPTS}"
export EFI_PART="$P1"
export BOOT_PART="$P2"
export LUKS_NAME

env -i \
  HOSTNAME="${HOSTNAME}" \
  BTRFS_OPTS="${BTRFS_OPTS}" \
  EFI_PART="${EFI_PART}" \
  BOOT_PART="${BOOT_PART}" \
  LUKS_NAME="${LUKS_NAME}" \
  PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
  chroot /mnt /bin/bash -c "/root/post-chroot.sh"

umount -R /mnt || true
swapoff -a || true
cryptsetup close "$LUKS_NAME" || true
shutdown -r now

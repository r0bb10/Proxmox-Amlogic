#!/usr/bin/env bash
set -euo pipefail

assets=/usr/lib/proxmox-amlogic/x96-max-plus
ampart="$assets/ampart"
bootloader="$assets/x96maxplus-u-boot.bin.sd.bin"
overload="$assets/u-boot-x96maxplus.bin"
target=""
dry_run=0

die() { printf 'error: %s\n' "$1" >&2; exit 1; }
info() { printf '%s\n' "$1"; }

usage() {
    cat <<'EOF'
Usage: install-to-emmc [--dry-run] [--target /dev/mmcblkN]

Install the running X96 Max+ USB system to inactive eMMC.

Options:
  --dry-run              Validate inputs and print the write plan only
  --target DEVICE        Explicit eMMC disk; required if detection is ambiguous
  -h, --help             Show this help
EOF
}

while (($#)); do
    case "$1" in
        --dry-run) dry_run=1 ;;
        --target) (($# >= 2)) || die "--target needs a device"; target=$2; shift ;;
        -h|--help) usage; exit 0 ;;
        *) die "unknown option: $1" ;;
    esac
    shift
done

[[ $(id -u) -eq 0 ]] || die "run as root"
for command in awk dd findmnt lsblk mkfs.ext4 mkfs.vfat mount od parted partprobe sync tar tr umount; do
    command -v "$command" >/dev/null || die "missing command: $command"
done
[[ -x "$ampart" ]] || die "missing bundled ampart tool: $ampart"
for file in \
    "$bootloader" \
    "$overload" \
    /boot/zImage \
    /boot/uInitrd \
    /boot/uEnv.txt \
    /boot/boot-emmc.scr \
    /boot/boot-emmc.cmd \
    /boot/boot.ini \
    /boot/boot-emmc.ini \
    /boot/emmc_autoscript \
    /boot/u-boot.usb \
    /boot/u-boot.sd \
    /boot/dtb/amlogic/meson-sm1-x96-max-plus.dtb; do
    [[ -s "$file" ]] || die "missing required boot file: $file"
done
[[ $(dd if=/boot/zImage bs=1 skip=56 count=4 status=none | od -An -tx1 | tr -d '[:space:]') == 41524d64 ]] \
    || die "zImage is not a raw ARM64 Image"

root_disk=$(findmnt -no PKNAME / || true)
[[ -n "$root_disk" ]] || die "cannot determine the running root disk"

if [[ -z "$target" ]]; then
    mapfile -t candidates < <(
        lsblk -dnpo NAME,TYPE \
            | awk -v root_disk="$root_disk" '$2 == "disk" && $1 ~ /\/mmcblk[0-9]+$/ && $1 !~ ("/" root_disk "$") { print $1 }'
    )
    ((${#candidates[@]} == 1)) || die "cannot uniquely detect inactive eMMC; use --target /dev/mmcblkN"
    target=${candidates[0]}
fi

[[ $target =~ ^/dev/mmcblk[0-9]+$ ]] || die "target must be an eMMC disk such as /dev/mmcblk2"
[[ -b $target ]] || die "target is not a block device: $target"
[[ $(lsblk -dnro TYPE "$target") == disk ]] || die "target is not a whole disk: $target"
[[ $(basename "$target") != "$root_disk" ]] || die "the running root filesystem is already on $target"

backup="$assets/emmc-bootloader-backup.img"
root_uuid=$(< /proc/sys/kernel/random/uuid)
info "Source root disk: $root_disk"
info "Target eMMC:      $target"
info "Bootloader:       $bootloader"
info "New root UUID:    $root_uuid"

if ((dry_run)); then
    info ""
    info "DRY RUN: no eMMC, filesystem, mount, or bootloader operation will be performed."
    info "Planned write sequence:"
    info "  1. Back up the first 4 MiB to $backup if no valid backup exists."
    info "  2. Unmount and remove existing Linux partitions on $target."
    info "  3. Run ampart dclone and verify its data::-1:4 snapshot."
    info "     Verified ampart layout: boot 117 MiB..628 MiB, root 629 MiB..end."
    info "     Fallback X96 Max+ layout: boot 68 MiB..579 MiB, root 1350 MiB..end."
    info "  4. Create FAT32 BOOT_EMMC and ext4 ROOTFS_EMMC partitions."
    info "  5. Write the mainline U-Boot payload and format both partitions."
    info "  6. Copy the running boot and root filesystems, then update uEnv.txt and fstab."
    exit 0
fi

printf 'Type INSTALL %s to erase and install to this eMMC: ' "$target"
read -r confirmation
[[ $confirmation == "INSTALL $target" ]] || die "installation cancelled"

backup_valid() {
    [[ -s $backup ]] || return 1
    [[ $(dd if="$backup" bs=1 skip=510 count=2 status=none | od -An -tx1 | tr -d '[:space:]') == 55aa ]]
}

info "1/6 Backing up the existing eMMC bootloader"
if ! backup_valid; then
    mkdir -p "$(dirname "$backup")"
    dd if="$target" of="$backup" bs=1M count=4 conv=fsync status=progress
fi

info "2/6 Preparing the Amlogic eMMC layout"
mapfile -t partitions < <(
    parted -ms "$target" print 2>/dev/null \
        | awk -F: '$1 ~ /^[0-9]+$/ { print $1 }' \
        || true
)
for number in "${partitions[@]}"; do
    partition="${target}p${number}"
    findmnt -rn -S "$partition" >/dev/null && umount -f "$partition"
    parted -s "$target" rm "$number"
done

boot_start=68
root_start=1350
if "$ampart" "$target" --mode dclone data::-1:4 >/dev/null 2>&1; then
    snapshot=$("$ampart" "$target" --mode dsnapshot 2>/dev/null || true)
    snapshot=${snapshot%%$'\n'*}
    if [[ $snapshot == data::-1:4 ]]; then
        boot_start=117
        root_start=629
        info "Verified ampart layout: boot ${boot_start} MiB, root ${root_start} MiB"
    else
        info "ampart snapshot was not verified; using the X96 Max+ fallback layout"
    fi
else
    info "ampart did not prepare this eMMC; using the X96 Max+ fallback layout"
fi

info "3/6 Partitioning and formatting eMMC"
parted -s "$target" mklabel msdos
parted -s "$target" mkpart primary fat32 "${boot_start}MiB" "$((boot_start + 511))MiB"
parted -s "$target" set 1 lba on
parted -s "$target" mkpart primary ext4 "${root_start}MiB" 100%
partprobe "$target"
for _ in {1..10}; do
    [[ -b ${target}p1 && -b ${target}p2 ]] && break
    sleep 1
done
[[ -b ${target}p1 && -b ${target}p2 ]] || die "eMMC partitions did not appear"

info "4/6 Writing mainline U-Boot and filesystems"
dd if="$bootloader" of="$target" conv=fsync bs=1 count=444 status=progress
dd if="$bootloader" of="$target" conv=fsync bs=512 skip=1 seek=1 status=progress
mkfs.vfat -F 32 -n BOOT_EMMC "${target}p1"
mkfs.ext4 -F -q -U "$root_uuid" -L ROOTFS_EMMC -m 0 "${target}p2"

work=$(mktemp -d)
trap 'umount -f "$work/boot" "$work/root" 2>/dev/null || true; rmdir "$work/boot" "$work/root" "$work" 2>/dev/null || true' EXIT
mkdir "$work/boot" "$work/root"

info "5/6 Copying boot files"
mount "${target}p1" "$work/boot"
cp -a /boot/. "$work/boot/"
rm -rf "$work/boot/System Volume Information"
rm -f "$work/boot"/s9* "$work/boot"/aml*
mv "$work/boot/boot-emmc.scr" "$work/boot/boot.scr"
mv "$work/boot/boot-emmc.cmd" "$work/boot/boot.cmd"
mv "$work/boot/boot-emmc.ini" "$work/boot/boot.ini"
sed -i 's|u-boot.ext|u-boot.emmc|g' "$work/boot/boot.ini"
if [[ -f "$work/boot/u-boot.ext" ]]; then
    cp "$work/boot/u-boot.ext" "$work/boot/u-boot.emmc"
else
    cp "$overload" "$work/boot/u-boot.ext"
    cp "$overload" "$work/boot/u-boot.emmc"
fi
chmod 0755 "$work/boot/u-boot.ext" "$work/boot/u-boot.emmc"
sed -i "s|root=.*console=ttyAML0|root=UUID=${root_uuid} rootflags=data=writeback rw rootwait rootfstype=ext4 console=ttyAML0|" "$work/boot/uEnv.txt"
sync
umount "$work/boot"

info "6/6 Copying root filesystem"
mount "${target}p2" "$work/root"
mkdir -p "$work/root"/{boot,dev,media,mnt,proc,run,sys,tmp}
chmod 1777 "$work/root/tmp"
for directory in etc home opt root selinux srv usr var; do
    [[ -d /$directory ]] && tar -C / -cf - "$directory" | tar -C "$work/root" -xpf -
done
ln -s usr/bin "$work/root/bin"
ln -s usr/lib "$work/root/lib"
ln -s usr/sbin "$work/root/sbin"
cat > "$work/root/etc/fstab" <<EOF
UUID=$root_uuid / ext4 defaults,noatime 0 1
LABEL=BOOT_EMMC /boot vfat defaults 0 2
tmpfs /tmp tmpfs defaults,nosuid 0 0
EOF
sync
umount "$work/root"

printf 'Installed to %s. Power off, remove USB media, then boot from eMMC.\n' "$target"

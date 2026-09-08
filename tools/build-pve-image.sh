#!/usr/bin/env bash
set -euo pipefail

root=$(realpath "$(dirname "$0")/..")
assets="$root/assets/x96-max-plus"
kernel_deb=""
runtime_deb=""
output="$root/dist/proxmox-ve-amlogic.img"
stage=all
reset=0

usage() {
    cat <<EOF
usage: $0 --kernel-deb PATH --runtime-deb PATH [--output PATH] [--stage STAGE] [--reset]

Stages: bootstrap, proxmox, configure, assemble, compress, all, clean
EOF
}

while (($#)); do
    case "$1" in
        --kernel-deb) kernel_deb=${2:?missing value for --kernel-deb}; shift 2 ;;
        --runtime-deb) runtime_deb=${2:?missing value for --runtime-deb}; shift 2 ;;
        --output) output=${2:?missing value for --output}; shift 2 ;;
        --stage) stage=${2:?missing value for --stage}; shift 2 ;;
        --reset) reset=1; shift ;;
        --help|-h) usage; exit 0 ;;
        *) usage >&2; exit 2 ;;
    esac
done

die() { printf 'error: %s\n' "$1" >&2; exit 1; }
[[ $stage == clean || -n $kernel_deb ]] || die "--kernel-deb is required"
[[ $stage == clean || -n $runtime_deb ]] || die "--runtime-deb is required"
[[ $(id -u) -eq 0 ]] || die "run as root"
[[ $stage == clean || -s $kernel_deb ]] || die "kernel package not found: $kernel_deb"
[[ $stage == clean || -s $runtime_deb ]] || die "kernel runtime package not found: $runtime_deb"
for command in curl dd debootstrap du gzip parted partprobe mkfs.vfat mkfs.ext4 mkimage rsync losetup mount umount; do
    command -v "$command" >/dev/null || die "missing command: $command"
done

work=${WORKDIR:-"$root/.dev/image-build"}
rootfs="$work/rootfs"
state="$work/.state"
root_min_gib=${IMG_ROOT_GIB:-0}
root_reserve_gib=${IMG_ROOT_RESERVE_GIB:-1}
root_align_mib=${IMG_ROOT_ALIGN_MIB:-256}
[[ $root_min_gib =~ ^[0-9]+$ ]] || die "IMG_ROOT_GIB must be a non-negative integer"
[[ $root_reserve_gib =~ ^[0-9]+$ ]] || die "IMG_ROOT_RESERVE_GIB must be a non-negative integer"
[[ $root_align_mib =~ ^[1-9][0-9]*$ ]] || die "IMG_ROOT_ALIGN_MIB must be a positive integer"
mirror=${DEBIAN_MIRROR:-http://deb.debian.org/debian}
proxmox_key_url=${PROXMOX_KEY_URL:-https://enterprise.proxmox.com/debian/proxmox-archive-keyring-trixie.gpg}
hostname=${PVE_HOSTNAME:-pve}
domain=${PVE_DOMAIN:-localdomain}
loop=""

mark() { touch "$state/$1"; }
complete() { [[ -e "$state/$1" ]]; }
chroot_exec() {
    chroot "$rootfs" env DEBIAN_FRONTEND=noninteractive LANG=C.UTF-8 LC_ALL=C.UTF-8 "$@"
}
mount_chroot() {
    mkdir -p "$rootfs"/{proc,sys,dev}
    for directory in proc sys dev; do
        mountpoint -q "$rootfs/$directory" || {
            mount --rbind "/$directory" "$rootfs/$directory"
            mount --make-rslave "$rootfs/$directory"
        }
    done
}
unmount_chroot() {
    umount -R -f "$rootfs/proc" "$rootfs/sys" "$rootfs/dev" 2>/dev/null || true
}
cleanup() {
    unmount_chroot
    if [[ -n $loop ]]; then
        umount -f "$work/mnt-boot" "$work/mnt-root" 2>/dev/null || true
        losetup -d "$loop" 2>/dev/null || true
    fi
}
trap cleanup EXIT

clean() {
    unmount_chroot
    rm -rf "$work"
}

bootstrap() {
    complete bootstrap && return
    mkdir -p "$work" "$state"
    if [[ ! -x "$rootfs/usr/bin/apt-get" ]]; then
        debootstrap --arch=arm64 --variant=minbase trixie "$rootfs" "$mirror"
    fi
    mount_chroot
    cp /etc/resolv.conf "$rootfs/etc/resolv.conf"
    cat > "$rootfs/usr/sbin/policy-rc.d" <<'EOF'
#!/bin/sh
exit 101
EOF
    chmod 0755 "$rootfs/usr/sbin/policy-rc.d"
    cat > "$rootfs/etc/apt/sources.list" <<EOF
deb $mirror trixie main contrib non-free-firmware
EOF
    printf 'LANG=C.UTF-8\n' > "$rootfs/etc/default/locale"
    cp "$kernel_deb" "$rootfs/tmp/kernel.deb"
    cp "$runtime_deb" "$rootfs/tmp/proxmox-amlogic-kernel-runtime.deb"
    chroot_exec dpkg --configure -a
    chroot_exec apt-get update -qq
    chroot_exec apt-get install -y -qq \
        /tmp/proxmox-amlogic-kernel-runtime.deb /tmp/kernel.deb \
        ca-certificates locales kmod initramfs-tools u-boot-tools \
        openssh-server chrony cron postfix iputils-ping parted bsdextrautils tar dosfstools \
        e2fsprogs fdisk util-linux rsync
    rm -f "$rootfs/tmp/kernel.deb" "$rootfs/tmp/proxmox-amlogic-kernel-runtime.deb"
    mark bootstrap
}

proxmox() {
    complete proxmox && return
    complete bootstrap || die "run bootstrap first"
    mount_chroot
    cat > "$rootfs/usr/sbin/policy-rc.d" <<'EOF'
#!/bin/sh
exit 101
EOF
    chmod 0755 "$rootfs/usr/sbin/policy-rc.d"
    mkdir -p "$rootfs/etc/apt/keyrings" "$rootfs/etc/apt/sources.list.d" "$rootfs/etc/apt/preferences.d"
    rm -f "$rootfs/etc/apt/sources.list"
    cat > "$rootfs/etc/apt/sources.list.d/debian.sources" <<'EOF'
Types: deb
URIs: http://deb.debian.org/debian
Suites: trixie trixie-updates
Components: main contrib non-free-firmware
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg

Types: deb
URIs: http://security.debian.org/debian-security
Suites: trixie-security
Components: main contrib non-free-firmware
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg
EOF
    curl -fsSL "$proxmox_key_url" -o "$rootfs/etc/apt/keyrings/proxmox-archive-keyring.gpg"
    cat > "$rootfs/etc/apt/sources.list.d/proxmox.sources" <<'EOF'
Types: deb
URIs: http://download.proxmox.com/debian/pve
Suites: trixie
Components: pve-no-subscription
Architectures: arm64 amd64
Signed-By: /etc/apt/keyrings/proxmox-archive-keyring.gpg
EOF
    cat > "$rootfs/etc/apt/preferences.d/no-stock-kernels" <<'EOF'
Package: proxmox-ve proxmox-default-kernel proxmox-kernel-* linux-image-*
Pin: version *
Pin-Priority: -1
EOF
    chroot_exec dpkg --configure -a
    chroot_exec apt-get update -qq
    chroot_exec apt-get install -y -qq proxmox-archive-keyring
    rm -f "$rootfs/etc/apt/keyrings/proxmox-archive-keyring.gpg"
    sed -i 's|/etc/apt/keyrings/proxmox-archive-keyring.gpg|/usr/share/keyrings/proxmox-archive-keyring.gpg|' "$rootfs/etc/apt/sources.list.d/proxmox.sources"
    chroot_exec apt-get install -y -qq \
        ifupdown2 ksm-control-daemon pve-manager pve-qemu-kvm qemu-server \
        pve-edk2-firmware-aarch64 zfsutils-linux isc-dhcp-client
    chroot_exec apt-get purge -y -qq 'linux-image-*'
    mark proxmox
}

configure() {
    complete configure && return
    complete proxmox || die "run proxmox first"
    mount_chroot
    modules=("$rootfs"/usr/lib/modules/*)
    [[ -d "${modules[0]}" ]] || die "kernel modules missing"
    release=$(basename "${modules[0]}")
    image="$rootfs/usr/lib/proxmox-kernel/$release/Image"
    [[ -s "$image" ]] || die "raw ARM64 Image missing for $release"
    initrd="$rootfs/var/lib/proxmox-kernel/$release/initrd.img-$release"
    if [[ ! -s "$initrd" ]]; then
        # Package installation precedes creation of the U-Boot FAT /boot layout.
        # The normal post-install hook writes beside its kernel argument on ext4.
        source_initrd="$rootfs/usr/lib/proxmox-kernel/$release/initrd.img-$release"
        [[ -s "$source_initrd" ]] || die "initramfs missing for $release"
        mkdir -p "$(dirname "$initrd")"
        mv "$source_initrd" "$initrd"
    fi
    dtb="$rootfs/usr/lib/proxmox-kernel/$release/meson-sm1-x96-max-plus.dtb"
    [[ -s "$dtb" ]] || die "kernel DTB missing for $release"
    [[ -s "$state/root-uuid" ]] || cat /proc/sys/kernel/random/uuid > "$state/root-uuid"
    root_uuid=$(<"$state/root-uuid")
    printf '%s\n' "$hostname" > "$rootfs/etc/hostname"
    printf '%s.%s\n' "$hostname" "$domain" > "$rootfs/etc/mailname"
    cat > "$rootfs/etc/hosts" <<EOF
127.0.0.1 localhost.localdomain localhost
::1 localhost ip6-localhost ip6-loopback
127.0.1.1 $hostname.$domain $hostname
EOF
    cat > "$rootfs/etc/fstab" <<EOF
UUID=$root_uuid / ext4 defaults,noatime 0 1
LABEL=BOOT /boot vfat defaults 0 2
tmpfs /tmp tmpfs defaults,nosuid 0 0
EOF
    mkdir -p "$rootfs/etc/network" "$rootfs/etc/ssh/sshd_config.d" "$rootfs/etc/systemd/system/getty.target.wants"
    cat > "$rootfs/etc/network/interfaces" <<'EOF'
auto lo
iface lo inet loopback

iface eth0 inet manual

auto vmbr0
iface vmbr0 inet dhcp
    bridge-ports eth0
    bridge-stp off
    bridge-fd 0
EOF
    printf 'PermitRootLogin yes\n' > "$rootfs/etc/ssh/sshd_config.d/99-root.conf"
    ln -sf /lib/systemd/system/serial-getty@.service "$rootfs/etc/systemd/system/getty.target.wants/serial-getty@ttyAML0.service"
    printf 'root:root\n' | chroot_exec chpasswd
    chroot_exec postconf -e "myhostname = $hostname.$domain"
    chroot_exec postconf -e 'inet_interfaces = loopback-only'
    chroot_exec postconf -e 'mydestination = $myhostname, localhost.$mydomain, localhost'
    : > "$rootfs/etc/machine-id"
    rm -f "$rootfs/var/lib/dbus/machine-id"
    ln -s /etc/machine-id "$rootfs/var/lib/dbus/machine-id"
    chroot_exec debconf-set-selections <<<'debconf debconf/frontend select Noninteractive'
    printf 'LANG=C.UTF-8\n' > "$rootfs/etc/default/locale"
    chroot_exec locale-gen C.UTF-8
    rm -f "$rootfs/etc/pve/local/"*.pem
    mkdir -p "$rootfs/usr/lib/proxmox-amlogic/x96-max-plus"
    cp "$assets"/ampart "$assets"/u-boot-x96maxplus.bin "$assets"/x96maxplus-u-boot.bin.sd.bin "$rootfs/usr/lib/proxmox-amlogic/x96-max-plus/"
    cp "$root/tools/install-to-emmc.sh" "$rootfs/usr/sbin/install-to-emmc"
    chmod 0755 "$rootfs/usr/sbin/install-to-emmc"
    rm -f "$rootfs/usr/sbin/policy-rc.d"
    chroot_exec apt-get clean
    rm -rf "$rootfs/var/lib/apt/lists/"*
    mark configure
}

assemble() {
    complete configure || die "run configure first"
    root_uuid=$(<"$state/root-uuid")
    modules=("$rootfs"/usr/lib/modules/*)
    release=$(basename "${modules[0]}")
    image="$rootfs/usr/lib/proxmox-kernel/$release/Image"
    dtb="$rootfs/usr/lib/proxmox-kernel/$release/meson-sm1-x96-max-plus.dtb"
    boot="$work/boot"
    rm -rf "$boot"
    mkdir -p "$boot/dtb/amlogic" "$(dirname "$output")"
    cp "$image" "$boot/zImage"
    mkimage -A arm -O linux -T ramdisk -C none -d "$rootfs/var/lib/proxmox-kernel/$release/initrd.img-$release" "$boot/uInitrd" >/dev/null
    cp "$dtb" "$boot/dtb/amlogic/meson-sm1-x96-max-plus.dtb"
    cp "$assets"/s905_autoscript "$assets"/s905_autoscript.cmd \
        "$assets"/aml_autoscript "$assets"/aml_autoscript.cmd \
        "$assets"/emmc_autoscript "$assets"/emmc_autoscript.cmd \
        "$assets"/boot.scr "$assets"/boot.cmd \
        "$assets"/boot-emmc.scr "$assets"/boot-emmc.cmd \
        "$assets"/boot.ini "$assets"/boot-emmc.ini \
        "$assets"/u-boot.usb "$assets"/u-boot.sd \
        "$assets"/u-boot-x96maxplus.bin "$boot/"
    cat > "$boot/uEnv.txt" <<EOF
LINUX=/zImage
INITRD=/uInitrd
FDT=/dtb/amlogic/meson-sm1-x96-max-plus.dtb
APPEND=root=UUID=$root_uuid rootflags=data=writeback rw rootwait rootfstype=ext4 console=ttyAML0,115200n8 console=tty0 no_console_suspend consoleblank=0 fsck.fix=yes fsck.repair=yes net.ifnames=0 max_loop=128 cgroup_enable=cpuset cgroup_memory=1 cgroup_enable=memory swapaccount=1 video=HDMI-A-1:1920x1080@60e plymouth.enable=0
EOF
    image="$work/image.img"
    rm -f "$image" "$output" "$output.gz" "$state/compress"
    # Leave room for upgrades, then round up to keep partition sizes predictable.
    root_bytes=$(du -sx --apparent-size --block-size=1 "$rootfs" | cut -f1)
    root_bytes=$((root_bytes + root_reserve_gib * 1024 * 1024 * 1024))
    root_min_bytes=$((root_min_gib * 1024 * 1024 * 1024))
    ((root_bytes >= root_min_bytes)) || root_bytes=$root_min_bytes
    root_align_bytes=$((root_align_mib * 1024 * 1024))
    root_bytes=$(((root_bytes + root_align_bytes - 1) / root_align_bytes * root_align_bytes))
    image_bytes=$((512 * 1024 * 1024 + root_bytes))
    truncate -s "$image_bytes" "$image"
    parted -s "$image" mklabel msdos mkpart primary fat32 4MiB 516MiB set 1 lba on mkpart primary ext4 516MiB 100%
    dd if="$assets/x96maxplus-u-boot.bin.sd.bin" of="$image" conv=fsync,notrunc bs=1 count=444 status=none
    dd if="$assets/x96maxplus-u-boot.bin.sd.bin" of="$image" conv=fsync,notrunc bs=512 skip=1 seek=1 status=none
    truncate -s "$image_bytes" "$image"
    loop=$(losetup -Pf --show "$image")
    for _ in {1..10}; do
        [[ -b "${loop}p1" && -b "${loop}p2" ]] && break
        partprobe "$loop"
        sleep 1
    done
    [[ -b "${loop}p1" && -b "${loop}p2" ]] || die "loop partitions did not appear"
    mkdir -p "$work/mnt-boot" "$work/mnt-root"
    mkfs.vfat -F 32 -n BOOT "${loop}p1"
    mkfs.ext4 -F -q -U "$root_uuid" -L rootfs "${loop}p2"
    mount "${loop}p1" "$work/mnt-boot"
    cp -a "$boot/." "$work/mnt-boot/"
    umount "$work/mnt-boot"
    mount "${loop}p2" "$work/mnt-root"
    rsync -aHAX --numeric-ids --exclude='/proc/*' --exclude='/sys/*' --exclude='/dev/*' --exclude='/tmp/*' "$rootfs/" "$work/mnt-root/"
    mkdir -p "$work/mnt-root"/{dev,proc,sys,tmp}
    chmod 1777 "$work/mnt-root/tmp"
    umount "$work/mnt-root"
    losetup -d "$loop"
    loop=""
    mv "$image" "$output"
    mark assemble
    printf 'Built %s\n' "$output"
}

compress() {
    complete compress && return
    complete assemble || die "run assemble first"
    [[ -s "$output" ]] || die "image missing: $output"
    gzip -9 -n -f -k "$output"
    mark compress
    printf 'Built %s.gz\n' "$output"
}

if ((reset)); then
    clean
fi
case "$stage" in
    bootstrap) bootstrap ;;
    proxmox) proxmox ;;
    configure) configure ;;
    assemble) assemble ;;
    compress) compress ;;
    all) bootstrap; proxmox; configure; assemble; compress ;;
    clean) clean ;;
    *) die "unknown stage: $stage" ;;
esac

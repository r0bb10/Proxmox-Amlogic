#!/usr/bin/env bash
set -euo pipefail

root=$(realpath "$(dirname "$0")/..")
work="$root/image-build"
out_dir="$root/dist"
rootfs="$work/rootfs"

board_dtb="${BOARD_DTB:-meson-sm1-x96-max-plus.dtb}"
root_gib="${IMG_ROOT_GIB:-2}"
skeleton_url="${SKELETON_URL:-https://github.com/ophub/amlogic-s9xxx-armbian/releases/download/Armbian_trixie_arm64_server_2026.08/Armbian_26.08.0_amlogic_s905x3_trixie_6.18.44_server_2026.08.15.img.gz}"
debian_mirror="${DEBIAN_MIRROR:-http://deb.debian.org/debian}"
kernel_repo_uri="${KERNEL_REPO_URI:-https://r0bb10.github.io/PVE-Amlogic-Kernel/}"
fallback_hostname="debian"
stage="${1:-all}"

die() { printf 'error: %s\n' "$1" >&2; exit 1; }
need_root() { [[ $(id -u) -eq 0 ]] || die "this stage requires root (sudo)"; }

for t in debootstrap parted mkfs.vfat mkfs.ext4 mkimage rsync curl losetup gpg; do
    command -v "$t" >/dev/null || die "missing tool: $t"
done

mkdir -p "$work" "$out_dir"

mount_chroot_binds() {
    mountpoint -q "$rootfs/proc" || mount --bind /proc "$rootfs/proc" 2>/dev/null || mount -t proc proc "$rootfs/proc"
    mountpoint -q "$rootfs/sys"  || mount --bind /sys  "$rootfs/sys"
    mountpoint -q "$rootfs/dev"  || mount --bind /dev  "$rootfs/dev"
}
umount_chroot_binds() {
    umount -R -f "$rootfs/proc" "$rootfs/sys" "$rootfs/dev" 2>/dev/null || true
}

chroot_exec() {
    chroot "$rootfs" env DEBIAN_FRONTEND=noninteractive HOME=/root "$@"
}

# ---------------------------------------------------------------- skeleton

do_skeleton() {
    need_root
    cd "$work"
    if [[ ! -s skeleton.img ]]; then
        [[ -s skeleton.img.gz ]] || curl -fL --retry 3 -o skeleton.img.gz "$skeleton_url"
        gunzip -kf skeleton.img.gz
    fi
    local loop
    loop=$(losetup -Pf --show skeleton.img)
    trap 'umount -f mnt-skeleton 2>/dev/null; losetup -d '"$loop"' 2>/dev/null' RETURN
    mkdir -p mnt-skeleton boot-skeleton
    mount "${loop}p1" mnt-skeleton
    rm -rf boot-skeleton
    cp -a mnt-skeleton/. boot-skeleton/
    umount mnt-skeleton
    losetup -d "$loop"
    trap - RETURN
    printf 'skeleton: %s files extracted\n' "$(find boot-skeleton -type f | wc -l)"
}

# ------------------------------------------------------------- debootstrap

do_debootstrap() {
    need_root
    cd "$work"
    if [[ ! -x rootfs/bin/sh && ! -x rootfs/usr/bin/sh ]]; then
        debootstrap --arch=arm64 --variant=minbase trixie rootfs "$debian_mirror"
    fi
    mkdir -p rootfs/proc rootfs/sys rootfs/dev
    mount_chroot_binds
    cp /etc/resolv.conf rootfs/etc/resolv.conf.build
    ln -sf resolv.conf.build rootfs/etc/resolv.conf
    printf 'debootstrap: %s packages installed\n' "$(chroot_exec dpkg -l 2>/dev/null | grep -c '^ii')"
}

# ----------------------------------------------------------------- packages

do_packages() {
    need_root
    cd "$work"
    [[ -x rootfs/usr/bin/apt-get ]] || die "run the debootstrap stage first"
    mount_chroot_binds

    cat > rootfs/usr/sbin/policy-rc.d <<'EOF'
#!/bin/sh
exit 101
EOF
    chmod +x rootfs/usr/sbin/policy-rc.d

    cat > rootfs/etc/apt/sources.list <<EOF
deb $debian_mirror trixie main contrib non-free-firmware
EOF
    chroot_exec apt-get update -qq
    chroot_exec apt-get install -y -qq gnupg wget ca-certificates locales

    mkdir -p rootfs/etc/apt/keyrings
    rm -f rootfs/etc/apt/keyrings/kernel.gpg
    curl -fsSL "${kernel_repo_uri}gpg.key" \
        | gpg --batch --yes --dearmor -o rootfs/etc/apt/keyrings/kernel.gpg

    cat > rootfs/etc/apt/sources.list <<EOF
deb $debian_mirror trixie main contrib non-free-firmware
deb [signed-by=/etc/apt/keyrings/kernel.gpg] $kernel_repo_uri trixie main
EOF

    chroot_exec apt-get update -qq

    kpkg=$(chroot_exec sh -c "apt-cache pkgnames linux-image- 2>/dev/null" \
        | grep -E '^linux-image-[0-9].*-pve$' | sort -V | tail -1)
    [[ -n "$kpkg" ]] || die "no linux-image-*-pve package found in repositories"

    header_pkgs=""
    [[ "${KEEP_HEADERS:-0}" == 1 ]] && header_pkgs="linux-headers-${kpkg#linux-image-}"

    DEBIAN_FRONTEND=noninteractive chroot_exec apt-get install -y \
        kmod \
        initramfs-tools \
        u-boot-tools \
        openssh-server \
        chrony \
        cron \
        dosfstools \
        e2fsprogs \
        fdisk \
        ifupdown \
        bridge-utils \
        isc-dhcp-client \
        iputils-ping \
        dialog \
        "$kpkg" \
        $header_pkgs

    do_configure

    # strip kernel repo + key from the final image: kernel updates happen
    # via image rebuilds, not apt upgrade on the box
    cat > rootfs/etc/apt/sources.list <<EOF
deb $debian_mirror trixie main contrib non-free-firmware
EOF
    rm -f rootfs/etc/apt/keyrings/kernel.gpg
    rmdir rootfs/etc/apt/keyrings 2>/dev/null || true

    # drop package caches: ~330 MB of dead weight in the final image
    chroot_exec apt-get clean
    rm -rf rootfs/var/lib/apt/lists/* rootfs/var/log/apt/* rootfs/var/cache/debconf/*

    umount_chroot_binds
    rm -f rootfs/usr/sbin/policy-rc.d
}

# ---------------------------------------------------------------- configure

do_configure() {
    cd "$work"
    local release
    release=$(ls rootfs/usr/lib/modules | grep -E '^[0-9].*-pve$' | sort -V | tail -1)
    [[ -n "$release" ]] || die "no -pve kernel found in rootfs modules"
    printf '%s\n' "$release" > kernel-release.env
    printf 'configure: kernel release %s\n' "$release"

    if [[ ! -s root-uuid.env ]]; then
        cat /proc/sys/kernel/random/uuid > root-uuid.env
    fi
    local root_uuid
    root_uuid=$(cat root-uuid.env)

    echo "$fallback_hostname" > rootfs/etc/hostname
    cat > rootfs/etc/hosts <<EOF
127.0.0.1   localhost.localdomain localhost
::1         localhost ip6-localhost ip6-loopback
EOF
    rm -f rootfs/etc/resolv.conf rootfs/etc/resolv.conf.build

    mkdir -p rootfs/etc/network
    cat > rootfs/etc/network/interfaces <<'EOF'
auto lo
iface lo inet loopback

iface eth0 inet manual

auto vmbr0
iface vmbr0 inet dhcp
    bridge_ports eth0
    bridge_stp off
    bridge_fd 0
EOF

    cat > rootfs/etc/fstab <<EOF
UUID=$root_uuid  /      ext4  defaults,noatime  0 1
LABEL=BOOT       /boot  vfat  defaults          0 2
tmpfs            /tmp   tmpfs defaults,nosuid    0 0
EOF

    mkdir -p rootfs/etc/ssh/sshd_config.d
    printf 'PermitRootLogin yes\n' > rootfs/etc/ssh/sshd_config.d/99-root.conf

    # fixed credentials: root/root, changed by hand later
    printf 'root:root\n' | chroot_exec chpasswd

    mkdir -p rootfs/etc/systemd/system/getty.target.wants
    ln -sf /lib/systemd/system/serial-getty@.service \
        rootfs/etc/systemd/system/getty.target.wants/serial-getty@ttyAML0.service

    : > rootfs/etc/machine-id
    rm -f rootfs/var/lib/dbus/machine-id
    ln -s /etc/machine-id rootfs/var/lib/dbus/machine-id

    # silence debconf for all future package operations (no TTY dialogs)
    chroot_exec debconf-set-selections <<<'debconf debconf/frontend select Noninteractive'

    # avoid perl locale warnings from PVE's en_US.UTF-8 default
    echo 'LANG=C.UTF-8' > rootfs/etc/default/locale
    chroot_exec locale-gen C.UTF-8

    printf 'configure: done\n'
}

# ----------------------------------------------------------------- assemble

do_assemble() {
    need_root
    cd "$work"
    local release root_uuid
    release=$(cat kernel-release.env)
    root_uuid=$(cat root-uuid.env)
    [[ -s rootfs/boot/vmlinuz-$release ]] || die "kernel missing in rootfs/boot"

    rm -rf boot-final && cp -a boot-skeleton boot-final
    # prune skeleton leftovers: stale kernel files make initramfs-tools try to
    # regenerate initrds for kernels whose modules do not exist
    rm -f boot-final/armbian_first_run.txt.template \
          boot-final/uEnv.txt.before-usb-quirk-test \
          boot-final/*-ophub* \
          boot-final/initrd.img-* boot-final/uInitrd-* \
          boot-final/config-* boot-final/System.map-* \
          boot-final/extlinux/* 2>/dev/null || true
    rmdir boot-final/extlinux 2>/dev/null || true
    rm -rf 'boot-final/System Volume Information' 2>/dev/null || true
    cp -a rootfs/boot/vmlinuz-$release boot-final/zImage
    mkimage -A arm -O linux -T ramdisk -C none \
        -d "rootfs/boot/initrd.img-$release" boot-final/uInitrd
    local dtb_path="boot-final/dtb/amlogic/$board_dtb"
    [[ -s "$dtb_path" ]] || die "dtb not present in skeleton: $dtb_path"

    sed -e "s|^LINUX=.*|LINUX=/zImage|" \
        -e "s|^INITRD=.*|INITRD=/uInitrd|" \
        -e "s|^FDT=.*|FDT=/dtb/amlogic/$board_dtb|" \
        -e "s|^APPEND=.*|APPEND=root=UUID=$root_uuid rw rootwait rootfstype=ext4 console=ttyAML0,115200n8 console=tty0 no_console_suspend consoleblank=0 fsck.fix=yes fsck.repair=yes net.ifnames=0 max_loop=128 cgroup_enable=cpuset cgroup_memory=1 cgroup_enable=memory swapaccount=1 video=HDMI-A-1:1920x1080@60e plymouth.enable=0|" \
        boot-skeleton/uEnv.txt > boot-final/uEnv.txt

    local img="dist-debian-arm64-s905x3.img"
    rm -f "$img"
    truncate -s $((512*1024*1024 + root_gib*1024*1024*1024)) "$img"
    parted -s "$img" mklabel msdos \
        mkpart primary fat32 4MiB 516MiB \
        set 1 lba on \
        mkpart primary ext4 516MiB 100%

    local loop
    loop=$(losetup -Pf --show "$img")
    trap 'umount -f mnt-p1 mnt-p2 2>/dev/null; losetup -d '"$loop"' 2>/dev/null' RETURN
    mkdir -p mnt-p1 mnt-p2
    mkfs.vfat -n BOOT -F32 "${loop}p1"
    mkfs.ext4 -U "$root_uuid" -L rootfs -F "${loop}p2"

    mount "${loop}p1" mnt-p1
    cp -a boot-final/. mnt-p1/
    sync
    umount mnt-p1

    mount "${loop}p2" mnt-p2
    rsync -aHAX --numeric-ids \
        --exclude='/proc/*' --exclude='/sys/*' --exclude='/dev/*' --exclude='/tmp/*' \
        rootfs/ mnt-p2/
    mkdir -p mnt-p2/{dev,proc,sys,tmp}
    chmod 1777 mnt-p2/tmp
    sync
    umount mnt-p2
    losetup -d "$loop"
    trap - RETURN

    # release free blocks back so compression actually works
    fallocate --dig-holes "$img" 2>/dev/null || true

    mkdir -p "$out_dir"
    mv "$img" "$out_dir/$img"
    (cd "$out_dir" && sha256sum "$img" > "$img.sha256")
    if command -v zstd >/dev/null; then
        zstd -q -19 -T0 "$out_dir/$img" -o "$out_dir/$img.zst"
    fi
    printf 'assemble: %s/%s (%s GiB root)\n' "$out_dir" "$img" "$root_gib"

}

# ------------------------------------------------------------------- clean

do_clean() {
    need_root
    cd "$work"
    mountpoint -q rootfs/proc && umount -R -f rootfs/{proc,sys,dev} || true
    rm -rf rootfs boot-final mnt-* skeleton.img skeleton.img.gz
}

case "$stage" in
    skeleton)    do_skeleton ;;
    debootstrap) do_debootstrap ;;
    packages)    do_packages ;;
    configure)   do_configure ;;
    assemble)    do_assemble ;;
    clean)       do_clean ;;
    all)
        do_skeleton
        do_debootstrap
        do_packages
        do_assemble
        ;;
    *) die "usage: $0 [all|skeleton|debootstrap|packages|configure|assemble|clean]" ;;
esac

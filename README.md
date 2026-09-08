# Proxmox VE Kernel for Amlogic Devices

Native ARM64 Proxmox VE kernel builds for the AMedia X96 Max+ and similar
Amlogic TV boxes.

## How It Works

This repository builds the latest available official [Proxmox VE](https://github.com/proxmox)
kernel source and configuration, then applies only the patches needed for the X96 Max+
U-Boot boot layout. The resulting package keeps the normal Proxmox kernel
userspace and modules while deploying the U-Boot kernel, initramfs, and device
tree payload required by the board.

## Device Tree Patch

Proxmox VE already includes generic support for Amlogic SM1 devices. The device
tree patch in this repository adds the board-specific description for the
AMedia X96 Max+ (S905X3), including its hardware configuration and bootable
device tree.

Support for other Amlogic boards can be added in the same way. Pull requests
for tested board support are welcome.

## Usage

Download the latest kernel package from the [GitHub releases page](https://github.com/r0bb10/Proxmox-Amlogic/releases) and install it on the target ARM64
system:

```bash
cd /tmp
curl -LO https://github.com/r0bb10/Proxmox-Amlogic/releases/latest/download/proxmox-kernel-<version>_arm64.deb
dpkg -i proxmox-kernel-<version>_arm64.deb
```

Replace `<version>` with the package filename published by the release. The
package requires `u-boot-tools`; install it first if it is not already present.

## Build Your Own Proxmox VE Image

Anyone can clone this repository and run the **Build PVE Image** GitHub Action.
It creates a minimal Debian system with `debootstrap`, installs Proxmox VE from
its official repositories, and includes the latest kernel built by this
repository.

The workflow produces a compressed full-disk image artifact. Flash it to a USB
drive or SD card to boot the device, then use the included installer to copy it
to eMMC.

The image boots directly into the latest available Proxmox VE packages.

## Kernel Cleanup

Images built by this repository include a small cleanup service. After a kernel
update, it waits for the next successful boot, confirms that the new kernel is
running, then removes superseded custom kernel packages and their module trees.

The X96 Max+ U-Boot layout has space for one active kernel payload and no
fallback mechanism. Cleanup therefore happens only after the new kernel has
booted, keeping the root filesystem tidy without removing the kernel needed for
the current boot.

## Disclaimer

The Proxmox VE kernel and userspace come from [Proxmox](https://github.com/proxmox),
and the Debian base system comes from its official upstream project. The U-Boot
profile is provided by [unifreq](https://github.com/unifreq), and the image
layout was inspired by [OPhub](https://github.com/ophub).

This repository does not replace those projects. It bundles them with only the
board-specific patches needed for the X96 Max+ to boot and run correctly.

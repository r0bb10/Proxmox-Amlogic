# X96 Max+ Boot Assets

These files were extracted from Ophub's Armbian 26.11.0 S905X3 Trixie image
(2026-09-01) and are retained to build and install images without downloading
an upstream image at build time.

Source release:

```
https://github.com/ophub/amlogic-s9xxx-armbian/releases/download/Armbian_trixie_arm64_server_2026.09/Armbian_26.11.0_amlogic_s905x3_trixie_6.18.48_server_2026.09.01.img.gz
```

- `x96maxplus-u-boot.bin.sd.bin` is the tested mainline eMMC bootloader.
- `u-boot-x96maxplus.bin` is the FAT boot overload payload used as
  `u-boot.ext` and `u-boot.emmc` after installation.
- Boot-control scripts and their source files are copied verbatim to the FAT
  partition. Do not regenerate or locally rewrite them.
- `ampart` prepares the proprietary Amlogic eMMC layout before repartitioning.
- The builder substitutes only the PVE raw `zImage`, `uInitrd`, X96 DTB, and
  root UUID, then writes the mainline U-Boot binary to the raw image disk.

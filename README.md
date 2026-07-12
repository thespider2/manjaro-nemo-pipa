# Nemomobile for Xiaomi Pad 6 (openSUSE + pipa flash layout)

Follows **current upstream** Nemomobile on **openSUSE Tumbleweed / OBS**, then post-processes into the **same flash layout as Ultramarine OS and EndeavourOS**.

## Flash partition mapping

| Image file | Target partition | Contents |
|---|---|---|
| `silicium.img` | `boot_ab` | Mu-Silicium UEFI |
| `nemo_esp.raw` | `rawdump` | ESP (FAT, GRUB EFI) |
| `nemo_boot.raw` | `cust` | `/boot` (kernel, initramfs, DTB, GRUB) |
| `nemo_rootfs.raw` | `userdata` / `linux` | Root filesystem (Nemo + pipa-pkgs) |

```bash
./flash.sh                  # single-boot → userdata
./flash-multiboot.sh linux  # multiboot → linux partition
```

## What CI builds

1. Download OBS `openSUSE-Tumbleweed-ARM-NEMO.aarch64-rootfs*.tar.xz`
2. Inject **pipa-pkgs** (`linux-pipa`, firmware, sensors, audio, …)
3. Apply `nemo-device-pipa` overlays (sensorfw / Pulse / camera)
4. Emit `nemo_{esp,boot,rootfs}.raw` + Mu-Silicium + flash scripts

## Sources

| | |
|--|--|
| Nemo UI | [devel:NemoMobile](https://build.opensuse.org/project/show/devel:NemoMobile) |
| Hardware | [pipa-pkgs](https://thespider2.github.io/pipa-pkgs/repo/) |
| Device glue | [nemo-pipa-packaging](https://github.com/thespider2/nemo-pipa-packaging) |

Default logins (upstream Nemo): `root`/`linux` or `nemo`/`1234`.

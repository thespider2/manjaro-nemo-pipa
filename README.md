# Nemomobile for Xiaomi Pad 6 (openSUSE + pipa flash layout)

Follows **upstream Nemomobile on openSUSE / OBS** (same rootfs family as the
PinePhone NEMO JeOS image), then post-processes into the **Ultramarine /
EndeavourOS pipa flash layout**.

See [docs/upstream-nemo-image.md](docs/upstream-nemo-image.md) for how the
PinePhone full image is built and how pipa maps onto that model.

## Flash partition mapping

CI artifacts are **xz-compressed**. `flash.sh` decompresses automatically.

| Image file | Target partition | Contents |
|---|---|---|
| `silicium.img.xz` | `boot_ab` | Mu-Silicium UEFI |
| `nemo_esp.raw.xz` | `rawdump` | ESP (FAT, GRUB EFI) |
| `nemo_boot.raw.xz` | `cust` | `/boot` (kernel, initramfs, DTB, GRUB) |
| `nemo_rootfs.raw.xz` | `userdata` / `linux` | Full Nemo + Glacier apps + pipa HW |

```bash
./flash.sh                  # single-boot → userdata
./flash-multiboot.sh linux  # multiboot → linux partition
```

## What a “full” pipa image includes (default)

1. OBS `openSUSE-Tumbleweed-ARM-NEMO.aarch64-rootfs*.tar.xz` (same stack as PinePhone)
2. **Full Glacier apps** injected from `devel:NemoMobile` (calc, files, gallery, clock, keyboard, …)
3. **PulseAudio + libssc deps** from openSUSE Tumbleweed ports
4. **pipa-pkgs**: `linux-pipa`, firmware, UCM, sensors, Qualcomm helpers, libcamera/qcam
5. Session like upstream JeOS `config.sh`: user `nemo`, linger, **Lipstick via user-session**, `graphical.target`
6. pipa glue: eglfs (card1), unblank, speaker TDM route, USB RNDIS SSH, dsme masked (avoids RTC reboot-loops)

Default logins: `root`/`linux`, `nemo`/`1234`.

## Build locally

```bash
# Full flashable set (needs root for loop mounts)
sudo ./scripts/ci-build-image.sh

# Or patch an existing rootfs.raw toward full UI
sudo IMAGE_MODE=full INJECT_FULL_PACKAGES=1 ./scripts/patch-rootfs.sh /path/to/nemo_rootfs.raw
fastboot flash userdata /path/to/nemo_rootfs.raw
```

Bring-up / console-only (no UI):

```bash
sudo IMAGE_MODE=bringup ./scripts/patch-rootfs.sh /path/to/nemo_rootfs.raw
```

## Sources

| | |
|--|--|
| Nemo UI / PinePhone image | [devel:NemoMobile](https://build.opensuse.org/project/show/devel:NemoMobile) |
| Hardware | [pipa-pkgs](https://thespider2.github.io/pipa-pkgs/repo/) |
| Device glue | [nemo-pipa-packaging](https://github.com/thespider2/nemo-pipa-packaging) |

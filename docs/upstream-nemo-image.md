# Upstream NemoMobile image model (PinePhone / PineTab)
#
# OBS project: devel:NemoMobile
# Image package: JeOS (kiwi), flavors:
#   - NEMO-pinephone.kiwi  → openSUSE-Tumbleweed-ARM-NEMO-pinephone*.raw.xz
#   - NEMO-rootfs.aarch64.kiwi → openSUSE-Tumbleweed-ARM-NEMO.aarch64-rootfs*.tar.xz
#   - NEMO-efi.aarch64.kiwi → generic EFI NEMO disk
#
# There is no separate "PineTab" kiwi today — installation docs reuse the
# PinePhone NEMO image. The important bits are identical for any NEMO JeOS:
#
# 1. Bootstrap = openSUSE JeOS base + device firmware/kernel
# 2. UI metapackage = patterns-nemomobile-nemomobile
#      Requires: lipstick-glacier-home, glacier-settings, glacier-wayland-session,
#                fingerterm, nemo-theme-glacier, glacier-devicelock-plugin,
#                nemo-devicelock-daemon-cli
# 3. config.sh (when kiwi_iname matches NEMO-*):
#      - create user nemo / password 1234
#      - groups: wheel,audio,input,video,...
#      - enable mce, dsme, nemo-devicelock
#      - add devel:NemoMobile zypper repo
#      - agetty autologin nemo on tty1
#      - user default.target → user-session.target
#      - enable lipstick.service in user default.target.wants
#
# Xiaomi Pad 6 (pipa) cannot use the PinePhone raw image (different SoC/boot).
# We take the same NEMO rootfs tarball and post-process it:
#   OBS rootfs + inject-full-packages (Glacier apps + Pulse/deps)
#            + pipa-pkgs (linux-pipa, firmware, sensors, audio UCM, …)
#            + configure-nemo-session (eglfs, unblank, linger, lipstick)
#            + configure-pipa-hardware (Qualcomm stack, speaker route, maliit)
#            → nemo_{esp,boot,rootfs}.raw + Mu-Silicium
#
# Build:
#   sudo ./scripts/ci-build-image.sh
# Flash:
#   ./images/flash.sh

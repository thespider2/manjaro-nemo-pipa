# CI image builder for Manjaro Nemomobile on pipa (aarch64 runners).
FROM menci/archlinuxarm:base-devel

RUN pacman-key --init && pacman-key --populate archlinuxarm && \
    sed -i '/^CheckSpace$/s/^/#/' /etc/pacman.conf && \
    sed -i '/^\[options\]$/a DisableSandbox' /etc/pacman.conf && \
    pacman -Sy --noconfirm && \
    pacman -S --noconfirm \
      git wget rsync sudo \
      arch-install-scripts e2fsprogs dosfstools mtools \
      zip unzip tar xz parted || \
    pacman -S --noconfirm git wget rsync sudo arch-install-scripts e2fsprogs dosfstools mtools zip unzip tar xz

# manjaro-arm-tools is Manjaro-specific; attempt install from community if mirrored,
# otherwise ci-build-image.sh stages the profile recipe until tools are available.
RUN pacman -S --noconfirm manjaro-arm-tools 2>/dev/null || \
    echo "manjaro-arm-tools not in Arch ARM repos — profile recipe mode"

WORKDIR /build
COPY profiles /build/profiles
COPY scripts /build/scripts
COPY Makefile README.md /build/
RUN chmod +x /build/scripts/*.sh

ENV CI=1 OUT_DIR=/out
VOLUME ["/out"]
ENTRYPOINT ["/bin/bash", "/build/scripts/ci-build-image.sh"]

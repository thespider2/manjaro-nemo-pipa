# opensuse-nemo-pipa (repo: manjaro-nemo-pipa)

Xiaomi Pad 6 port following **current upstream Nemomobile**: **openSUSE Tumbleweed + OBS**.

> Repo name is historical; content is openSUSE, not Manjaro.

## Upstream sources

| What | Where |
|------|--------|
| Nemo RPMs | [devel:NemoMobile](https://build.opensuse.org/project/show/devel:NemoMobile) → `https://download.opensuse.org/repositories/devel:/NemoMobile/openSUSE_Tumbleweed/` |
| Official images | [OBS images](https://download.opensuse.org/repositories/devel:/NemoMobile/images/) — e.g. `openSUSE-Tumbleweed-ARM-NEMO-efi.aarch64*.raw.xz` |
| Install docs | https://nemomobile.net/installation/ |
| Pipa device RPM | [nemo-pipa-packaging](https://github.com/thespider2/nemo-pipa-packaging) (CI builds **only** this) |

Default logins (upstream): `root` / `linux` or `nemo` / `1234`.

## What this repo does

CI (aarch64) downloads the latest **NEMO-efi aarch64** image from OBS, injects `nemo-device-pipa` config overlays, and publishes an artifact. It does **not** rebuild lipstick/mce/glacier.

Pipa kernel/firmware are still device-specific (not in OBS yet). The pipeline stages a Nemo rootfs/image ready for pipa boot integration (Mu-Silicium / `kernel-pipa` RPM work).

## CI

- GitHub Actions: `.github/workflows/build.yml` (`ubuntu-24.04-arm`)
- CircleCI: `.circleci/config.yml` (`arm.large`)

Local: `make validate` only (no image build on laptops).

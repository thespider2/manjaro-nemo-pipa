# Manjaro Nemomobile for Xiaomi Pad 6 (pipa)

From-scratch **Manjaro ARM** port of [Nemomobile](https://github.com/nemomobile-ux/nemo-images).

**Images are built in CI only** — not on a developer laptop.

| CI | Runner | Workflow |
|----|--------|----------|
| GitHub Actions | `ubuntu-24.04-arm` | `.github/workflows/build.yml` |
| CircleCI | `arm.large` | `.circleci/config.yml` |

Packages: [`nemo-pipa-packaging`](https://github.com/thespider2/nemo-pipa-packaging) (CI → Pages).  
Hardware: [`pipa-pkgs`](https://github.com/thespider2/pipa-pkgs) Arch repo.

## Local (validation only)

```bash
make validate   # checks profiles; does not build an image
```

## Credentials (upstream default)

```
user: manjaro
password: 123456
```

## Profiles

```
profiles/devices/pipa
profiles/editions/nemomobile
profiles/services/nemomobile
profiles/overlays/{nemomobile,pipa}/
```

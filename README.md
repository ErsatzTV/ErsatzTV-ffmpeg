# ErsatzTV FFmpeg

This repo builds the FFmpeg that [ErsatzTV](https://github.com/ErsatzTV/ErsatzTV) uses. Each release has:

- A docker image for `linux/amd64` and `linux/arm64`.
- Native builds for `linux64`, `linuxarm64` and `win64`.

The docker images and the native builds use the same patch set. The patches are in [`patches/`](patches). The patches apply in number order.

The docker images are modified versions of the images from [jrottenberg/ffmpeg](https://github.com/jrottenberg/ffmpeg) and [linuxserver/docker-ffmpeg](https://github.com/linuxserver/docker-ffmpeg). The native builds use [ErsatzTV/FFmpeg-Builds](https://github.com/ErsatzTV/FFmpeg-Builds), a fork of [BtbN/FFmpeg-Builds](https://github.com/BtbN/FFmpeg-Builds).

## Versions

A release tag has two parts: `<FFmpeg version>-<revision>`. For example, `8.1.2-1` is FFmpeg 8.1.2 with ErsatzTV revision 1.

- A new build of the same FFmpeg version gets the next revision: `8.1.2-1`, then `8.1.2-2`.
- A new FFmpeg version starts again at revision 1: `8.1.3-1`.
- `ffmpeg -version` shows the revision as `etv.<revision>`. The native builds show `n8.1.2-etv.1`. The docker image shows `8.1.2-etv.1`.

This scheme is not SemVer. SemVer reads `-1` as a prerelease. Compare the four numbers (major, minor, patch, revision) as integers. For example, `8.1.2-10` is newer than `8.1.2-9`.

## Releases do not change

A release tag and its files never change after publication. GitHub [immutable releases](https://docs.github.com/en/code-security/concepts/supply-chain-security/immutable-releases) enforce this. If a build needs a fix, the fix gets a new revision.

A new release is a GitHub prerelease first. A maintainer then promotes it. Promotion:

- Moves the floating docker tags to the new image.
- Makes the release the GitHub "latest" release.

Promotion does not change the files or the image.

The GitHub releases `8.1.2` and `7.1.1` are older than this scheme. They stay available, but they do not get updates. The `7.1.1` docker tag also does not get updates. The `8.1.2` docker tag is a floating tag.

## Docker

Image: `ghcr.io/ersatztv/ersatztv-ffmpeg`

| Tag | Changes | Use |
|---|---|---|
| `8.1.2-N@sha256:<digest>` | Never | Recommended. Update it yourself. |
| `8.1.2-N` | Never | Pinned to a revision. |
| `8.1.2` | At each promotion | Always the newest promoted revision of 8.1.2. |
| `latest` | At each promotion | Always the newest promoted revision. |

Use the digest pin if you must know which bytes you get. The Build section of the release notes shows the digest. ErsatzTV uses this type of pin.

A floating tag can change when you rebuild your image. The new revision can change FFmpeg behavior. Read the release notes before you update.

Example Dockerfile line:

```dockerfile
FROM ghcr.io/ersatztv/ersatztv-ffmpeg:8.1.2-1@sha256:<index digest from the release notes>
```

The images use `ghcr.io/linuxserver/baseimage-ubuntu:noble` (Ubuntu 24.04). FFmpeg is in `/usr/local/bin`.

The images do not include `ffplay`, `libfdk_aac` or other nonfree code. Use the built-in `aac` encoder.

Revision `8.1.2-1` and later do not include `linux/arm/v7`. The last `linux/arm/v7` image is `ghcr.io/ersatztv/ersatztv-ffmpeg:8.1.2@sha256:effcdf7b69c425f84e338c05cbf51807ac302651b70cac603b115c6cca2ab2e2`. This image does not get updates.

## Native builds

Each release has these files:

| File | Contents |
|---|---|
| `ffmpeg-n<version>-etv.<revision>-linux64-gpl-8.1.tar.xz` | Linux x86_64 |
| `ffmpeg-n<version>-etv.<revision>-linuxarm64-gpl-8.1.tar.xz` | Linux arm64 (aarch64) |
| `ffmpeg-n<version>-etv.<revision>-win64-gpl-8.1.zip` | Windows x86_64 |
| `ffmpeg-<version>.tar.bz2` | The upstream FFmpeg source release |
| `ersatztv-ffmpeg-<tag>-src.tar.xz` | This repo and the native build recipe at the release tag |
| `SHA256SUMS` | SHA-256 checksums of all the other files |

Each archive has one top-level directory. The directory has `bin/ffmpeg`, `bin/ffprobe`, `bin/ffplay` and `LICENSE.txt`. On Windows, the programs have the `.exe` extension.

The file names keep the same pattern for each release. Tools that find the archive with a pattern, for example `*-linux64-gpl-8.1.tar.xz`, continue to work.

### Supported systems

These baselines come from the upstream build recipe:

- Linux: glibc 2.28 or newer, and Linux kernel 4.18 or newer.
- Windows: Windows 10 22H2 or newer.

CI tests the native builds on GitHub-hosted Ubuntu 24.04 (x86_64 and arm64) and Windows runners. CI does not test other systems.

## Verify a release

Download the files that you need and `SHA256SUMS` into one directory. Then do these steps:

1. Make sure that the checksums are correct:

   ```sh
   sha256sum -c --ignore-missing SHA256SUMS
   ```

2. Make sure that GitHub Actions in this repo built the archive:

   ```sh
   gh attestation verify <archive> --repo ErsatzTV/ErsatzTV-ffmpeg
   ```

3. Make sure that GitHub Actions in this repo built the docker image:

   ```sh
   gh attestation verify oci://ghcr.io/ersatztv/ersatztv-ffmpeg@sha256:<index digest> --repo ErsatzTV/ErsatzTV-ffmpeg
   ```

The release notes show these commands with the correct digest.

The attestations connect each file to the workflow run and the commit that made it. The builds are not byte-for-byte reproducible. If you build the same commit again, the bytes will be different.

## Automatic updates

Default SemVer tools do not sort these tags correctly. For Renovate, use regex versioning:

```json
{
  "packageRules": [
    {
      "matchPackageNames": ["ghcr.io/ersatztv/ersatztv-ffmpeg"],
      "versioning": "regex:^(?<major>\\d+)\\.(?<minor>\\d+)\\.(?<patch>\\d+)-(?<build>\\d+)$"
    }
  ]
}
```

Make sure that your tool sorts `8.1.2-10` after `8.1.2-9`.

## Build and release

- [Build](docs/building.md) the docker images and the native builds.
- [Release](docs/releasing.md) a new revision. These steps are for maintainers.

## License

The builds are GPL version 3 or later. See [LICENSE](LICENSE). Each release includes the upstream FFmpeg source and this repo at the release tag.

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

Use the digest pin if you must know which bytes you get. The release notes show the digest. ErsatzTV uses this type of pin.

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

## Build

You must have `docker`, `git`, `jq` and a POSIX shell.

To build a docker image:

```sh
docker build \
  $(sh scripts/release-vars.sh "$(git rev-parse HEAD)" |
    grep -E '^(FFMPEG_VERSION|FFMPEG_SHA256|FFMPEG_EXTRA_VERSION)=' | sed 's/^/--build-arg /') \
  -f images/linux/amd64/Dockerfile .
```

To build a native target (`linux64`, `linuxarm64` or `win64`):

```sh
git submodule update --init
sh scripts/build-native.sh linux64 "$(git rev-parse HEAD)"
```

The archive goes into `native/FFmpeg-Builds/artifacts/`. The native build uses the dependency images in [`native/images.lock.json`](native/images.lock.json).

Local builds show `etv.dev.<commit>` in `ffmpeg -version`. Only the release workflow makes `etv.<revision>` builds.

## Maintainers

### Make a release

1. Increase `revision` in [`release.json`](release.json). For a new FFmpeg version, also change the version, tag, commit and tarball checksum, and set `revision` to 1. Make sure that all patches apply to the new version.
2. Add `release-notes/<tag>.md`. Write the changes that users can see.
3. Merge to `main`. Make sure that CI passes.
4. Push the tag. The tag must agree with `release.json`. Do not tag a commit that has `[no ci]` in its message.

   ```sh
   git tag 8.1.2-N
   git push origin 8.1.2-N
   ```

The [release workflow](.github/workflows/release.yml) builds and tests all targets. Then it publishes a prerelease. The prerelease is not `latest`.

If the workflow fails, look at the publish job:

- If the publish job did not start, you can move the tag. Disable the "release tags" ruleset, move the tag, then enable the ruleset again.
- If the publish job started, do not move the tag. Use the next revision.

### Promote a release

Get the index digest from the release notes. Then do these steps:

1. Log in to `ghcr.io` with a token that has `write:packages`.
2. Move the floating tags:

   ```sh
   docker buildx imagetools create \
     -t ghcr.io/ersatztv/ersatztv-ffmpeg:8.1.2 \
     -t ghcr.io/ersatztv/ersatztv-ffmpeg:latest \
     ghcr.io/ersatztv/ersatztv-ffmpeg@sha256:<index digest>
   ```

3. Make sure that both tags have the index digest:

   ```sh
   docker buildx imagetools inspect ghcr.io/ersatztv/ersatztv-ffmpeg:8.1.2
   docker buildx imagetools inspect ghcr.io/ersatztv/ersatztv-ffmpeg:latest
   ```

4. Make the release the latest release:

   ```sh
   gh release edit 8.1.2-N --prerelease=false --latest
   ```

5. Make sure that GitHub shows the new release as latest:

   ```sh
   gh api repos/ErsatzTV/ErsatzTV-ffmpeg/releases/latest --jq .tag_name
   ```

Do not promote an older revision after a newer one.

## License

The builds are GPL version 3 or later. See [LICENSE](LICENSE). Each release includes the upstream FFmpeg source and this repo at the release tag.

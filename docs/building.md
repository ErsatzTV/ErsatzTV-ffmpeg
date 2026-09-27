# Build ErsatzTV FFmpeg

Run the commands from the root of the repo.

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

The archive goes into `native/FFmpeg-Builds/artifacts/`. The native build uses the dependency images in [`native/images.lock.json`](../native/images.lock.json).

Local builds show `etv.dev.<commit>` in `ffmpeg -version`. Only the release workflow makes `etv.<revision>` builds.

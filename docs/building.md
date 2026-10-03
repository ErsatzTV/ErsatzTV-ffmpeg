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

## macOS

Build the macOS targets (`macos64` or `macosarm64`) on a Mac. You must have Xcode, `jq`, and these Homebrew tools: `autoconf`, `automake`, `libtool`, `meson`, `nasm`, `cmake`, `ninja` and `pkgconf`. An Apple silicon Mac can build both targets. CI builds both targets on an Apple silicon runner.

```sh
sh native/macos/build.sh macosarm64 "$(git rev-parse HEAD)"
```

The first build compiles the libraries in [`native/macos/deps.json`](../native/macos/deps.json) into `native/macos/work/<target>/prefix/`. On a GitHub runner, this takes 10 to 20 minutes. Later builds use these libraries again. To compile them again, delete the `prefix` directory. The build links the libraries statically. The build does not link Homebrew libraries.

The archive goes into `native/macos/artifacts/`. Local builds are not signed. To check an archive:

```sh
sh scripts/check-native-package.sh native/macos/artifacts/<archive> macosarm64 8.1.2 etv.dev.<commit> pkg
```

### Change a macOS library

1. Change the version, URL and `sha256` in [`deps.json`](../native/macos/deps.json). Use a release tarball, not a git branch.
2. If the build steps change, change the `build_<name>` function in [`build-deps.sh`](../native/macos/build-deps.sh).
3. Open a pull request. A change to `deps.json`, `env.sh` or `build-deps.sh` makes a new CI cache key, so CI compiles all the libraries again.

Local builds show `etv.dev.<commit>` in `ffmpeg -version`. Only the release workflow makes `etv.<revision>` builds.

# Build ErsatzTV FFmpeg

Run the commands from the root of the repo.

You must have `docker`, `git`, `jq` and a POSIX shell.

To build a docker image (`amd64` or `arm64`):

```sh
docker build \
  --build-arg DEPS_IMAGE=$(jq -er .amd64.image images/linux/deps.lock.json) \
  $(sh scripts/release-vars.sh "$(git rev-parse HEAD)" |
    grep -E '^(FFMPEG_VERSION|FFMPEG_SHA256|FFMPEG_EXTRA_VERSION)=' | sed 's/^/--build-arg /') \
  -f images/linux/amd64/Dockerfile .
```

The docker build starts from the dependency image in [`images/linux/deps.lock.json`](../images/linux/deps.lock.json). This image has the libraries from `images/linux/<arch>/deps.Dockerfile`. The docker build compiles only FFmpeg.

### Change a docker library

1. Change `images/linux/<arch>/deps.Dockerfile`.
2. Push the branch. The push starts the [deps workflow](../.github/workflows/deps.yml). The workflow builds the dependency images for `amd64` and `arm64`. When most layers must compile again, the `amd64` image takes approximately 100 minutes.
3. Copy the lock file from the workflow run summary to `images/linux/deps.lock.json`. The run also keeps the lock file as the `deps-lock` artifact.
4. Commit and push the lock file. Then open a pull request.

CI and the release workflow stop if the lock file does not agree with the `deps.Dockerfile` files.

To test a `deps.Dockerfile` change on your computer, build the dependency image and use its tag as `DEPS_IMAGE`:

```sh
docker build -t ersatztv-ffmpeg-deps:amd64 -f images/linux/amd64/deps.Dockerfile images/linux/amd64
```

### Update the Ubuntu base

A dependency image keeps the Ubuntu base that it was built on. To use a newer base, run the deps workflow on a branch without a recipe change, then do steps 3 and 4:

```sh
gh workflow run deps.yml --ref <branch>
```

The final stage of each docker image always uses the newest `noble` base when it builds.

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

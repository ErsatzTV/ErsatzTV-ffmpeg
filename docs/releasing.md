# Release ErsatzTV FFmpeg

These steps are for maintainers.

## Make a release

1. Increase `revision` in [`release.json`](../release.json). For a new FFmpeg version, also change the version, tag, commit and tarball checksum, and set `revision` to 1. Make sure that all patches apply to the new version.
2. Add `release-notes/<tag>.md`. Write the changes that users can see.
3. Merge to `main`. Make sure that CI passes.
4. Tag the `native/FFmpeg-Builds` submodule commit in the fork as `etv/<tag>`. The release workflow stops if this tag is missing or points to a different commit. A ruleset prevents changes to `etv/*` tags, so do this step immediately before the next step.

   ```sh
   git -C native/FFmpeg-Builds tag -a etv/8.1.2-N -m "Submodule pin of ErsatzTV-ffmpeg 8.1.2-N"
   git -C native/FFmpeg-Builds push origin etv/8.1.2-N
   ```

5. Push the tag. The tag must agree with `release.json`. Do not tag a commit that has `[no ci]` in its message.

   ```sh
   git tag 8.1.2-N
   git push origin 8.1.2-N
   ```

The [release workflow](../.github/workflows/release.yml) builds and tests all targets. Then it publishes a prerelease. The prerelease is not `latest`.

If the workflow fails, look at the publish job:

- If the publish job did not start, you can move the tag. Disable the "release tags" ruleset, move the tag, then enable the ruleset again. If the fix changes the `native/FFmpeg-Builds` submodule, use the next revision, because the fork's `etv/<tag>` tag cannot move.
- If the publish job started, do not move the tag. Use the next revision.

## Before the first release with a new signing setup

The release workflow signs and notarizes the macOS builds with the Apple organization secrets. Before you tag a release after a change to these secrets, to the certificate, or to [`sign.sh`](../native/macos/sign.sh) or the entitlements in [`native/macos/`](../native/macos), do a dry run on `main`:

```sh
gh workflow run ci.yml --ref main -f sign=true
```

The dry run signs and notarizes the macOS builds and checks the signatures. It does not publish anything.

## Test the macOS builds on hardware

The GitHub macOS runners cannot use VideoToolbox. Before you promote a release that changes the macOS builds, do these tests on at least one Apple silicon Mac and one Intel Mac. Use macOS 15, the oldest supported version, on at least one of them. A release changes the macOS builds if it changes a patch that applies to macOS, `native/macos/`, the configure flags, or the Xcode version.

Use the files from the published prerelease, not CI artifacts. Do these steps on each Mac:

1. Download the archive for the Mac and `SHA256SUMS` with `gh release download 8.1.2-N`. Make sure that the checksum is correct.
2. Check the archive, its signature and its notarization:

   ```sh
   sh scripts/check-native-package.sh <archive> <macos64|macosarm64> 8.1.2 etv.N pkg signed
   ```

3. Run the software and VideoToolbox integration tests of ErsatzTV Next with the extracted programs:

   ```sh
   export ETV_TEST_FFMPEG=$PWD/pkg/<archive name>/bin/ffmpeg
   export ETV_TEST_FFPROBE=$PWD/pkg/<archive name>/bin/ffprobe
   cargo test -p ffpipeline --test software -- --ignored --test-threads 1
   cargo test -p ffpipeline --test videotoolbox -- --ignored --test-threads 1
   ```

   The software tests must all pass. The VideoToolbox tests must pass, except for two known VideoToolbox limits that other FFmpeg builds also have: the interlaced H.264 tests on Apple silicon, and `copy_still_image` on Intel.

4. Run the readrate test with the macOS bash:

   ```sh
   /bin/bash patches/tests/readrate-sparse-stream-stall.sh "$ETV_TEST_FFMPEG"
   ```

5. Make sure that an `https` input works with certificate verification:

   ```sh
   "$ETV_TEST_FFMPEG" -tls_verify 1 -i https://<a valid https media URL> -t 1 -f null -
   "$ETV_TEST_FFMPEG" -tls_verify 1 -i https://self-signed.badssl.com/ -f null -
   ```

   The first command must work. The second command must fail with "certificate verify failed".

6. Make sure that a subtitle burn-in with `fontsdir` draws text, also when the font is not in `fontsdir`.

Keep a record of the results: the Mac, its macOS version, the archive checksum, the ErsatzTV Next commit, and the test counts.

After a change to the signing setup, also do this test on one Mac: download the archive with Safari, open it with Archive Utility, and run `bin/ffmpeg -version`. macOS must not show a Gatekeeper warning.

## Promote a release

If the release changes the macOS builds, do the [hardware tests](#test-the-macos-builds-on-hardware) first. Do not promote the release if a test fails.

Get the index digest from the Build section of the release notes. The release workflow writes this section. Then do these steps:

1. Make sure that the digest agrees with the fixed tag:

   ```sh
   docker buildx imagetools inspect ghcr.io/ersatztv/ersatztv-ffmpeg:8.1.2-N
   ```

2. Make sure that the release workflow built the image:

   ```sh
   gh attestation verify oci://ghcr.io/ersatztv/ersatztv-ffmpeg@sha256:<index digest> --repo ErsatzTV/ErsatzTV-ffmpeg
   ```

3. Log in to `ghcr.io` with a token that has `write:packages`.
4. Move the floating tags:

   ```sh
   docker buildx imagetools create \
     -t ghcr.io/ersatztv/ersatztv-ffmpeg:8.1.2 \
     -t ghcr.io/ersatztv/ersatztv-ffmpeg:latest \
     ghcr.io/ersatztv/ersatztv-ffmpeg@sha256:<index digest>
   ```

5. Make sure that both tags have the index digest:

   ```sh
   docker buildx imagetools inspect ghcr.io/ersatztv/ersatztv-ffmpeg:8.1.2
   docker buildx imagetools inspect ghcr.io/ersatztv/ersatztv-ffmpeg:latest
   ```

6. Make the release the latest release:

   ```sh
   gh release edit 8.1.2-N --prerelease=false --latest
   ```

7. Make sure that GitHub shows the new release as latest:

   ```sh
   gh api repos/ErsatzTV/ErsatzTV-ffmpeg/releases/latest --jq .tag_name
   ```

Do not promote an older revision after a newer one.

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

## Promote a release

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

# Experimental direct NV12 output

Patch 0022 lets libplacebo render directly into writable VAAPI NV12 surfaces
when `ETV_VAAPI_DIRECT_NV12=1` is set. Without that exact value, behavior is
unchanged. Patch 0022 requires patch 0019 and, by itself, keeps its synchronous
reverse-map wait. Patch 0023 adds the asynchronous handoff described below.
Neither patch changes libplacebo or claims an independent throughput gain.

The observed failure was blank green encoded output, sometimes with a successful
FFmpeg exit. The VAAPI-derived Vulkan context described one combined NV12 image,
while imported DRM images were separate R8/RG8 layers. Both the context and
imported images also lacked the color attachment usage required for rendering.
The opt-in describes separate planes before context initialization and adds
attachment usage to the context and writable import. The existing image
format/modifier query checks the actual import with that usage; unsupported
imports remain errors.

This assumes VAAPI's separate-plane NV12 export. The historical isolated probe
validated Intel ANV/iHD at 1920x1080, 8-bit SDR, using Y-tiled modifier
`0x100000000000002`. Two 270-frame clips were nonblank, decoded cleanly, and
matched the same shader through a download/upload reference for all 540 frames.
That probe predates this extracted patch. The extraction has forward/reverse
patch-application checks against the retained FFmpeg 8.1.2 source with patch
0019, but no new build or GPU run. AMD, other drivers/modifiers, HDR, 10-bit,
and long-running playback remain unverified. Patch 0019's broader hardware
results do not establish support for direct NV12 rendering.

## Manual check

After building the normal patch stack, use a short SDR source on an otherwise
idle test GPU. Replace the executable, input and DRM device as needed. This
recipe is provided for validation; it has not been run for this extraction.
It creates a new output file and refuses to overwrite an existing one.

```sh
ETV_VAAPI_DIRECT_NV12=1 ffmpeg -nostdin -hide_banner -n \
  -init_hw_device drm=dr:/dev/dri/renderD128 \
  -init_hw_device vaapi=va@dr -init_hw_device vulkan=vk@dr \
  -filter_hw_device vk -hwaccel vaapi -hwaccel_device va \
  -hwaccel_output_format vaapi -extra_hw_frames 16 -i input-sdr.mp4 \
  -vf 'hwmap=derive_device=drm,format=drm_prime,libplacebo=w=1920:h=1080:format=nv12:colorspace=bt709,format=vulkan,hwmap=derive_device=vaapi:reverse=1,format=vaapi' \
  -frames:v 270 -an -c:v h264_vaapi -qp 18 direct-nv12.mp4
```

Decode the whole output and inspect pictures; process success alone missed the
original failure. For a reference, replace
`hwmap=derive_device=vaapi:reverse=1` with
`hwdownload,format=nv12,hwupload=derive_device=vaapi` and write a different file.
Compare decoded frame hashes with identical source, renderer and encoder
settings. Keep the existing RGBA plus `scale_vulkan=format=nv12` route as the
default control with the environment variable unset. Modifier rejection is a
portability limit, not a reason to disable capability checking.

## Asynchronous handoff and execution depth

Patch 0023 builds on [PR #78](https://github.com/ErsatzTV/ErsatzTV-ffmpeg/pull/78).
It submits a bridge from the frame's Vulkan timeline to an exportable binary
semaphore, then imports its sync file into the target DMA-BUF objects. This lets
the consumer wait through GPU synchronization instead of explicitly blocking
the CPU. The frame remains referenced until submission completes. A one-slot
hardware-context compute pool becomes two slots so its next use need not
immediately wait for the previous one. Both paths keep pixels on the GPU.

Unsupported or failed synchronization retains the existing CPU wait. Imported
fds and the semaphore have frame lifetime; failure before submission discards
dependencies and restores a signaled fence before fallback.

Credit belongs to the upstream mechanisms:

- **Tymur Boiko**, [FFmpeg 25e187f84949](https://github.com/FFmpeg/FFmpeg/commit/25e187f8494966377a4b9d077260ce7b501a911c), introduced the timeline-to-exportable-binary-semaphore bridge for DRM mapping.
- **Lynne**, [FFmpeg 1d14f9f8c3e4](https://github.com/FFmpeg/FFmpeg/commit/1d14f9f8c3e4efb32000cb463ebb635ad6f2adb0), decoupled execution-pool depth from hardware queue count.

This is a focused adaptation to FFmpeg 8's reverse VAAPI mapping, not a new
invention or a complete backport of either commit. The retained-frame lifetime,
imported-fd handling and FFmpeg 8 failure recovery are integration differences.

The extraction was applied after patch 0022 and produced byte-identical
`hwcontext_vulkan.c` to the built fork revision `fd067276`. Forward and reverse
application checks passed. That combined fork has build and Intel GPU playback
evidence; the extracted PR has not had a separate GPU run or fault injection.
The measured producer-storage gain belongs to the separate libplacebo change;
it must not be attributed to this scheduling patch.

# Experimental direct NV12 output

Patch 0023 lets libplacebo render directly into writable VAAPI NV12 surfaces
when `ETV_VAAPI_DIRECT_NV12=1` is set. Without that exact value, behavior is
unchanged. It requires patch 0019 and keeps its synchronous reverse-map wait.
It does not change command-pool depth or libplacebo, and claims no speed gain.

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
That probe predates this extracted patch.

The extracted patch was later built in the packaged Docker image (with
`DIRECT_NV12_OUTPUT=1` and the libplacebo patch from #80, without any
asynchronous handoff patch) and run on an Intel i3-1220P (Gen12, ANV/iHD,
Mesa 25.2.8). ErsatzTV next's VAAPI libplacebo tone-mapping chain rendered
into this target for 1080p HDR fixtures (full frame, pillarbox, letterbox),
1280x720, and 2160p HDR10 and Dolby Vision 8.1 sources scaled with
`scale_vaapi`. Raw NV12 output was byte-identical to the RGBA plus
`scale_vulkan=format=nv12` route from the same image, 24-120 frames per case,
so both planes receive the complete picture. Multi-stream HLS runs with
`h264_vaapi` low-power encoding completed without errors. AMD, other
drivers/modifiers, 10-bit output and long-running playback remain unverified.
Patch 0019's broader hardware results do not establish support for direct NV12
rendering.

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

# Vulkan to VAAPI reverse-map synchronization

The reverse `hwmap` path can return the original VAAPI surface while Vulkan
is still writing it. A VAAPI encoder can then read incomplete frame contents.
This was observed as displaced rectangular fragments during motion and cuts;
both the encode and subsequent software decode completed without errors.

Patch 0019 waits for the Vulkan frame's timeline semaphores before returning
the original VAAPI surface. It uses the existing Vulkan frame lock and propagates
a failed wait. Frames stay in GPU memory. Other mapping pairs are unchanged.
The host wait trades some asynchronous overlap for correct ownership handoff.
It preserves the GPU path and avoids the slower workaround of copying every
frame to CPU memory and back. This is a narrowly scoped downstream correction,
not a general mapping redesign.

## Manual reproduction

Use the same Intel render device, driver/runtime libraries, input, and encoding
settings for control and patched binaries. Use a progressive H264 source with
movement and hard cuts. The original reproduction used a 480x360, 30fps source
scaled to 1440x1080 and padded to 1920x1080. A custom shader is not required to
trigger the problem.

Set `FFMPEG` to the binary being tested and `INPUT` to a suitable local source.
The following is the affected path (adjust the render device if necessary):

```sh
"$FFMPEG" -hide_banner -y \
  -init_hw_device drm=dr:/dev/dri/renderD128 \
  -init_hw_device vaapi=va@dr -init_hw_device vulkan=vk@dr \
  -filter_hw_device vk -hwaccel vaapi -hwaccel_device va \
  -hwaccel_output_format vaapi -extra_hw_frames 64 \
  -i "$INPUT" -t 12 -an \
  -vf 'hwmap=derive_device=drm,format=drm_prime,libplacebo=w=1440:h=1080:format=rgba:colorspace=bt709,format=vulkan,scale_vulkan=format=nv12,hwmap=derive_device=vaapi:reverse=1,format=vaapi,setsar=1,pad_vaapi=w=1920:h=1080:x=-1:y=-1:color=black,scale_vaapi=format=nv12:extra_hw_frames=64' \
  -c:v h264_vaapi -b:v 8M -maxrate 8M -bufsize 16M reverse-map.mp4
```

For a synchronized reference, replace only
`hwmap=derive_device=vaapi:reverse=1,format=vaapi` with
`hwdownload,format=nv12,hwupload=derive_device=vaapi,format=vaapi`, and write
to `cpu-reference.mp4`. This slower reference downloads/uploads pixels;
the patch does not.

Inspect the moving outputs around cuts and object movement. Compare decoded
frames as well; successful encoding and valid timestamps alone do not detect
this failure:

```sh
"$FFMPEG" -v error -i reverse-map.mp4 -map 0:v:0 -f framemd5 reverse-map.framemd5
"$FFMPEG" -v error -i cpu-reference.mp4 -map 0:v:0 -f framemd5 cpu-reference.framemd5
```

Repeat the affected encode. Race-dependent corruption can change between runs.
Frame-hash equality was achieved on the tested stack; if an encoder produces
nondeterministic output, inspect decoded differences and temporal alignment
instead of treating every hash mismatch as proof of this particular defect.

## Evidence boundary and retirement

The initial diagnostic used ErsatzTV 8.1.2-4. The correction was then built and
verified against 8.1.2-5 with its matching dependency image, release configure
options, all 18 release patches, and patch 0019. The resulting binary identifies
itself as `8.1.2-etv.5-vulkan-sync.1` and has SHA-256
`fb9e95d25f929cd394071dadc27afe2ff9c9defeacffa5f8de1b27fa8c5d2d95`.

For the 12-second reproduction, the CPU-transfer reference contained 360 decoded
frames. Stock 8.1.2-5 matched only 4 of those 360 frames. The patched run, its
repeat, and an unthrottled patched run each matched all 360 native-resolution
frames exactly. These checks establish correction of the observed corruption
on the tested stack.

The earlier controlled 8.1.2-4 timing sample illustrates why retaining the GPU
path matters:

| Path | Speed relative to real time | Output |
| --- | --- | --- |
| Original GPU path | 4.53x | Corrupt |
| CPU download/upload workaround | 3.33x | Clean |
| Patched GPU path | 4.77x | Clean |

This short sample supports avoiding the CPU-copy penalty; it does not establish
a general speedup over the original GPU path or a sustained capacity guarantee.
The 8.1.2-5 timing runs overlapped build activity, so their timings are not capacity
evidence.

The manifest records the checks performed. Do not infer AMD, other Intel
generations, macOS/Windows, or sustained multi-channel validation from these
results. No upstream FFmpeg acceptance is claimed.

The related upstream DRM-import wait-stage proposal
[PR25161](https://www.mail-archive.com/ffmpeg-devel@ffmpeg.org/msg191228.html)
did not repair this reproduction. Patch 0019 targets the reverse-unmap return
instead. Remove the carry when the pinned FFmpeg source fixes that handoff and
the affected-stack reproduction passes without the local patch.

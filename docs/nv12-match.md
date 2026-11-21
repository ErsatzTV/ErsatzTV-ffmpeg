# Single-pass NV12 output for libplacebo tone mapping (Match)

ErsatzTV next's VAAPI tone-mapping chain has libplacebo write an RGBA
picture, then runs a second GPU pass (`scale_vulkan=format=nv12`) to convert
it into the NV12 frame the encoder needs. Match makes libplacebo perform that
same conversion inside its own final pass and write the NV12 surface
directly. The output is the same bytes; the RGBA picture and the second pass
go away.

Current chain:

```
hwmap=derive_device=drm,format=drm_prime,
libplacebo=tonemapping=...:colorspace=bt709:color_primaries=bt709:color_trc=bt709:format=rgba,
scale_vulkan=format=nv12:out_range=limited,
hwmap=derive_device=vaapi:reverse=1,format=vaapi
```

With Match (needs `ETV_VAAPI_DIRECT_NV12=1` for patch 0023's writable target):

```
hwmap=derive_device=drm,format=drm_prime,
libplacebo=tonemapping=...:colorspace=bt709:color_primaries=bt709:color_trc=bt709:format=nv12:range=tv:nv12_output=match,
hwmap=derive_device=vaapi:reverse=1,format=vaapi
```

The encoder side is unchanged (`h264_vaapi`, including `low_power=1`).

## Building it

The amd64 Docker build argument `DIRECT_NV12_OUTPUT=1` rebuilds the pinned
libplacebo v7.360.1 with `patches/libplacebo/0001-nv12-direct-output-match.patch`.
That patch adds `pl_renderer_set_nv12_output()` and the
`PL_RENDERER_NV12_OUTPUT` marker. FFmpeg patch 0024 compiles the
`nv12_output` option into the libplacebo filter only when that marker is
present. So `ffmpeg -h filter=libplacebo` lists `nv12_output` only in builds
that implement it; a stock-libplacebo build has no such option. The option
is per filter instance and defaults to `off`.

Finding the option says the build implements Match. It does not say a given
GPU, driver or output qualifies: Match covers 8-bit limited-range BT.709 NV12
targets (full frame, or an even-aligned picture inside bars) on Vulkan
devices with fragment image stores. Anything else keeps libplacebo's normal
output path.

## How the output stays the same

1. RGB is left unencoded and dithered to 8 bits exactly as the RGBA output is
   dithered, so each pixel holds the texel value the RGBA route writes.
2. Those values are read back through a 256-entry UNORM8 ramp texture with a
   linear sampler, the conversion `scale_vulkan`'s `texture()` read applies.
3. `scale_vulkan`'s BT.709 matrix (`ff_fill_rgb2yuv_table`), limited-range
   scale and offset and top-left chroma placement follow, unchanged.
4. Y and UV are stored with `imageStore`, as `scale_vulkan` stores them. The
   libplacebo pass keeps its shader stage.

Steps 2 and 4 reuse the GPU's own conversions instead of imitating them: the
GPU's UNORM8 reads and writes are not exactly k/255, and exact float math
alone missed about 0.1% of luma bytes by one code value.

## Measurements

Intel i3-1220P (Gen12, ANV/iHD, Mesa 25.2.8), packaged image built from
`main` + patch 0023 + this change with `DIRECT_NV12_OUTPUT=1`.

Picture: raw NV12 (`hwdownload,format=nv12`) compared with `cmp` against the
RGBA route from the same image. Zero differing bytes for 24 frames each of
the 1080p HDR fixtures from ErsatzTV next (full frame, 1440x1080 pillarbox,
1920x800 letterbox) and 1280x720, and 120 frames each of a 2160p HDR10 and a
2160p Dolby Vision 8.1 episode downscaled with `scale_vaapi` first, as next
does for 4K sources.

Speed: concurrent FFmpeg processes, 720 frames (30 s) each, Hable, 1080p24,
`h264_vaapi` 5 Mbps low-power, AAC, HLS. Slowest process, mean of two
batches:

| Source | Streams | RGBA + `scale_vulkan` | Match | Throughput |
| --- | ---: | ---: | ---: | ---: |
| 1080p HDR fixture, full frame | 5 | 26.343 s | 23.573 s | +11.8% |
| 1440x1080 pillarbox | 5 | 22.137 s | 18.836 s | +17.5% |
| 1920x800 letterbox | 5 | 21.916 s | 18.467 s | +18.7% |
| 2160p HDR10 episode | 4 | 30.047 s | 28.151 s | +6.7% |

At four 4K HDR streams RGBA falls just short of real time and Match does not.
The 4K gain is smaller because decoding loads the video engine, which this
change does not touch. With three 4K streams paced at real time, render-engine
busy dropped from 71.0% to 62.4% at the same video-engine load.

## Scope of the claims

- Byte-identical on the tested Intel system (Gen12). On nine Intel generations
  (Skylake through Panther Lake, Mesa 25.2.8) the two routes compile to the
  same arithmetic. Chroma on other hardware also depends on `scale_vulkan`
  writing each 2x2 block's chroma from four invocations without a defined
  order, which no compile check can settle.
- AMD and other drivers have not been checked.
- libplacebo's own NV12 output with its Mitchell chroma filter can be written
  directly as well (a separate patch on top of this one, at about the RGBA
  route's speed); it is available if wanted.

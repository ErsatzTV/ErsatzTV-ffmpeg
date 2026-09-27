#!/usr/bin/env bash
#
# Reproducer for
#   0008-lavfi-qsvvpp-seed-output-surface-timestamp-from-the-input.patch
#   0009-lavfi-vf_vpp_qsv-add-pad-support-via-mfxExtVPPComposite.patch
#   0010-lavfi-vf_vpp_qsv-pad-honour-colour-matrix-and-range-snap-to-chroma-grid.patch
#
# vpp_qsv gains pad_w/pad_h/pad_x/pad_y/pad_color, implemented as a
# single-stream VPP composition (mfxExtVPPComposite): the scaled picture is
# placed at (pad_x, pad_y) in a pad_w x pad_h output surface and the remainder
# is filled with the composition background colour. Nothing in the runtime
# documentation forbids NumInputStream=1, but no in-tree filter uses it, so
# every case measures the result rather than trusting the runtime.
#
#   nv12-center        1280x720 testsrc2 padded to 1920x1080, centred. Border
#                      strips must be video black (Y=16 U=128 V=128); the
#                      picture region must be a lossless copy of the source.
#                      vpp_qsv's default async_depth=4 is in effect, so this
#                      also proves 0008: without it every output pts is 0.
#   nv12-offset-color  pad_x=100:pad_y=40:pad_color=red on a link tagged
#                      bt709/tv. The border must match the software pad filter
#                      on the same link within +-2 (0010; 0009 alone converts
#                      with BT.601 constants and fails this by ~18 in Y).
#   p010               nv12-center at 10 bit: borders 64/512/512.
#   scale-pad          the ErsatzTV geometry: 640x480 scaled to 1440x1080 and
#                      letterboxed into 1920x1080 in one VPP pass.
#   same-size          720x480 scaled to 720x404 back into a 720x480 canvas
#                      (canvas equals input size, so the passthrough shortcut
#                      must not swallow the pad).
#   odd-offset         pad_x=101:pad_y=41 must be snapped to 100/40 (0010);
#                      the picture-region psnr at (100,40) proves placement.
#   decoded-1088       1080p h264 decoded with -hwaccel qsv (surfaces are
#                      1920x1088, CropH=1080) padded to 1920x1200. The strip
#                      below the picture must be black and pts monotonic.
#   pipeline           decode, vpp_qsv scale+pad, overlay_qsv, h264_qsv.
#
# Probes (INFO only, never fail): composition is documented to skip every VPP
# filter except deinterlacing and scaling. Measured on libmfx-gen: procamp
# silently ignored (iHD 25.2.3 Alder Lake-N, 26.2.4 Arc A750); HDR10
# tonemapping dropped on Linux (iHD 26.2.2 Arc A310) but honoured on Windows
# D3D11; framerate conversion honoured everywhere. 0010 therefore rejects
# denoise/detail/procamp/tonemap/colour conversion with padding, so
# procamp-probe, range-probe and tonemap-probe report "REJECTED at
# configuration" on a current build; on a build with 0009 only they measure
# the runtime. tonemap-probe decodes an HDR10 HEVC sample with -hwaccel qsv so
# the frames carry the mastering-display side data vpp_qsv's tonemap=1
# requires; a setparams-tagged testsrc2 never engages the tonemapper.
#
# A vpp_qsv without pad_w is a FAIL, not a SKIP: that is the state without
# the patches. A QSV device that cannot be created is a SKIP (exit 77).
#
# Usage: vpp-qsv-pad.sh [/path/to/ffmpeg]
#        CASES="nv12-center p010" vpp-qsv-pad.sh /path/to/ffmpeg
#        QSV_CHILD_DEVICE=/dev/dri/renderD129 vpp-qsv-pad.sh   (Linux: DRM node)
#        QSV_CHILD_DEVICE=1 vpp-qsv-pad.sh                      (Windows: adapter index)
#        KEEP_LOGS=1 vpp-qsv-pad.sh
#
# Exit: 0 all runnable cases passed, 1 any case failed, 77 nothing was runnable.

set -uo pipefail

FFMPEG="${1:-${FFMPEG:-ffmpeg}}"
case "$FFMPEG" in */*) FFMPEG="$(cd "$(dirname "$FFMPEG")" && pwd)/$(basename "$FFMPEG")" ;; esac
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
sample="$here/../samples/h264-1920x1080-coded-1088.mkv"
overlay="$here/../samples/overlay-320x180.jpg"
# HDR10 HEVC with mastering-display and content-light SEI (vpp_qsv only
# tonemaps when the decoded frame carries that side data). Override with a
# real HDR10 file via TONEMAP_SAMPLE=/path.
hdr_sample="${TONEMAP_SAMPLE:-$here/../samples/1080p_hevc_10_hdr.ts}"

CASES="${CASES:-nv12-center nv12-offset-color p010 scale-pad same-size odd-offset decoded-1088 pipeline procamp-probe framerate-probe range-probe tonemap-probe}"
QSV_CHILD_DEVICE="${QSV_CHILD_DEVICE:-}"

logdir="$(mktemp -d)"
if [ -n "${KEEP_LOGS:-}" ]; then
    echo "logs:    $logdir"
else
    trap 'rm -rf "$logdir"' EXIT
fi

# Git Bash / MSYS2 (Windows): the runtime rewrites arguments that look like
# path lists, which mangles filtergraph strings ("file=/tmp/x:...") and lavfi
# source specs. Switch that off, and hand ffmpeg.exe Windows-style paths for
# the sample files. ffmpeg runs inside the log dir so every stats file in a
# filtergraph is a bare relative name on both platforms.
if command -v cygpath >/dev/null 2>&1; then
    export MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*'
    ffpath() { cygpath -m "$1"; }
else
    ffpath() { printf '%s\n' "$1"; }
fi
ff() { (cd "$logdir" && exec "$FFMPEG" "$@"); }

if ! "$FFMPEG" -version >/dev/null 2>&1; then
    echo "ERROR: cannot run ffmpeg: $FFMPEG" >&2
    exit 2
fi

devspec="qsv=hw:hw_any${QSV_CHILD_DEVICE:+,child_device=$QSV_CHILD_DEVICE}"
common=(-nostdin -hide_banner -nostats -loglevel verbose
        -init_hw_device "$devspec" -filter_hw_device hw)

pass=0; fail=0; skip=0

report_pass() { echo "PASS: $1 - $2"; pass=$((pass + 1)); }
report_fail() { echo "FAIL: $1 - $2"; fail=$((fail + 1)); }
report_info() { echo "INFO: $1 - $2"; }
report_skip() {
    echo "SKIP: $1 - $2"
    [ -n "${3:-}" ] && sed -n 's/^/       | /p' <<<"$(grep -iE "error|not (supported|available|found)|no such|failed|cannot|unknown|invalid" "$3" | tail -3)"
    skip=$((skip + 1))
}

# Mean of lavfi.signalstats.<KEY> over every frame in a metadata=print file.
stat_mean() {
    awk -F= -v key="lavfi.signalstats.$2" '$1 == key { s += $2; n++ } END { if (n) printf "%.2f", s / n; else print "nan" }' "$1"
}

within() {
    awk -v a="$1" -v b="$2" -v t="$3" 'BEGIN { if (a == "nan" || b == "nan") exit 1; d = a - b; if (d < 0) d = -d; exit !(d <= t) }'
}

showinfo_size() {
    grep -o ' s:[0-9]*x[0-9]*' "$1" | head -1 | cut -c4-
}

# "<frames> <non-increasing pts count>" from showinfo lines.
showinfo_pts_check() {
    awk '
        /\[Parsed_showinfo/ && / n: / {
            if (match($0, / pts: *-?[0-9]+/)) {
                p = substr($0, RSTART + 5, RLENGTH - 5) + 0
                n++
                if (n > 1 && p <= last) bad++
                last = p
            }
        }
        END { printf "%d %d\n", n, bad + 0 }' "$1"
}

psnr_average() {
    grep -o 'average:[0-9.inf]*' "$1" | tail -1 | cut -d: -f2
}

psnr_ok() {
    [ "$1" = "inf" ] && return 0
    awk -v v="$1" 'BEGIN { exit !(v + 0 >= 45) }'
}

check_border() {
    # check_border <case> <statsfile> <label> <Y> <U> <V> <tol>
    local name="$1" f="$2" label="$3" ey="$4" eu="$5" ev="$6" tol="$7" y u v
    y="$(stat_mean "$f" YAVG)"; u="$(stat_mean "$f" UAVG)"; v="$(stat_mean "$f" VAVG)"
    if within "$y" "$ey" "$tol" && within "$u" "$eu" "$tol" && within "$v" "$ev" "$tol"; then
        return 0
    fi
    report_fail "$name" "$label border is Y=$y U=$u V=$v, expected $ey/$eu/$ev (+-$tol)"
    return 1
}

run_probe_device() {
    local log="$logdir/probe.log"
    if ! ff "${common[@]}" -f lavfi -i "nullsrc=s=64x64:d=0.1" -f null - >"$log" 2>&1; then
        echo "SKIP: cannot create QSV device ($devspec)"
        sed -n 's/^/       | /p' <<<"$(grep -iE "error|failed|cannot|not " "$log" | tail -4)"
        exit 77
    fi
    grep -iE "VAAPI driver|Using device|Initialize MFX session|implementation" "$log" | head -3 | sed 's/^/         /'
    if ! "$FFMPEG" -hide_banner -h filter=vpp_qsv 2>/dev/null | grep '^ *pad_w ' >/dev/null; then
        echo "FAIL: vpp_qsv has no pad_w option in this ffmpeg (unpatched build)"
        exit 1
    fi
}

# --- synthetic upload cases -------------------------------------------------

# run_synthetic <case> <swfmt> <planar> <iw> <ih> <vpp args> <pw> <ph> <px> <py> <picw> <pich>
#               <Y> <U> <V> <tol> <checkpic 0|1> [setparams]
# Borders of zero size are not measured. checkpic=1 compares the picture region
# against the source (only valid when the picture is not scaled).
run_synthetic() {
    local name="$1" swfmt="$2" planar="$3" iw="$4" ih="$5" vppargs="$6"
    local W="$7" H="$8" px="$9" py="${10}" pw="${11}" ph="${12}"
    local ey="${13}" eu="${14}" ev="${15}" tol="${16}" checkpic="${17}" setparams="${18:-}"
    local log="$logdir/$name.log" ok=1
    local top="$logdir/$name.top" bottom="$logdir/$name.bottom" left="$logdir/$name.left" right="$logdir/$name.right"
    local graph="[0:v]format=$swfmt${setparams:+,$setparams},split[src][ref];"
    graph+="[src]hwupload,vpp_qsv=$vppargs,hwdownload,format=$swfmt,format=$planar,split=6[a][b][c][d][pic][info];"
    local maps=()
    if [ "$py" -gt 0 ]; then
        graph+="[a]crop=$W:$py:0:0,signalstats,metadata=print:file=${name}.top[ta];"; maps+=(-map "[ta]" -f null -)
    else graph+="[a]nullsink;"; fi
    if [ $((H - py - ph)) -gt 0 ]; then
        graph+="[b]crop=$W:$((H - py - ph)):0:$((py + ph)),signalstats,metadata=print:file=${name}.bottom[tb];"; maps+=(-map "[tb]" -f null -)
    else graph+="[b]nullsink;"; fi
    if [ "$px" -gt 0 ]; then
        graph+="[c]crop=$px:$H:0:0,signalstats,metadata=print:file=${name}.left[tc];"; maps+=(-map "[tc]" -f null -)
    else graph+="[c]nullsink;"; fi
    if [ $((W - px - pw)) -gt 0 ]; then
        graph+="[d]crop=$((W - px - pw)):$H:$((px + pw)):0,signalstats,metadata=print:file=${name}.right[td];"; maps+=(-map "[td]" -f null -)
    else graph+="[d]nullsink;"; fi
    if [ "$checkpic" = 1 ]; then
        graph+="[pic]crop=$pw:$ph:$px:${py}[picc];[ref]format=${planar}[refc];[picc][refc]psnr[tp];"; maps+=(-map "[tp]" -f null -)
    else graph+="[pic]nullsink;[ref]nullsink;"; fi
    graph+="[info]showinfo[ti]"; maps+=(-map "[ti]" -f null -)

    ff "${common[@]}" \
        -f lavfi -i "testsrc2=size=${iw}x${ih}:rate=25:duration=1" \
        -filter_complex "$graph" "${maps[@]}" >"$log" 2>&1
    local rc=$?
    if [ $rc -ne 0 ]; then
        report_fail "$name" "ffmpeg exited $rc: $(grep -iE 'error|MFX|invalid' "$log" | tail -1)"
        return 1
    fi

    local size; size="$(showinfo_size "$log")"
    if [ "$size" != "${W}x${H}" ]; then
        report_fail "$name" "output is ${size:-<none>}, expected ${W}x${H}"
        return 1
    fi

    [ -f "$top" ]    && { check_border "$name" "$top"    top    "$ey" "$eu" "$ev" "$tol" || ok=0; }
    [ -f "$bottom" ] && { check_border "$name" "$bottom" bottom "$ey" "$eu" "$ev" "$tol" || ok=0; }
    [ -f "$left" ]   && { check_border "$name" "$left"   left   "$ey" "$eu" "$ev" "$tol" || ok=0; }
    [ -f "$right" ]  && { check_border "$name" "$right"  right  "$ey" "$eu" "$ev" "$tol" || ok=0; }

    local p="n/a"
    if [ "$checkpic" = 1 ]; then
        p="$(psnr_average "$log")"
        if ! psnr_ok "${p:-nan}"; then
            report_fail "$name" "picture region psnr average is ${p:-<none>}, expected inf (>= 45 dB accepted)"
            ok=0
        fi
    fi

    read -r nframes badpts <<<"$(showinfo_pts_check "$log")"
    if [ "$nframes" -lt 20 ] || [ "$badpts" -ne 0 ]; then
        report_fail "$name" "$nframes output frames, $badpts non-increasing pts"
        ok=0
    fi

    [ $ok -eq 1 ] || return 1
    local f="$top"; [ -f "$f" ] || f="$left"
    report_pass "$name" "${W}x${H}, borders $(stat_mean "$f" YAVG)/$(stat_mean "$f" UAVG)/$(stat_mean "$f" VAVG), psnr $p, $nframes frames"
}

run_nv12_center() {
    run_synthetic nv12-center nv12 yuv420p 1280 720 "pad_w=1920:pad_h=1080" \
        1920 1080 320 180 1280 720 16 128 128 1 1
}

run_p010() {
    run_synthetic p010 p010le yuv420p10le 1280 720 "pad_w=1920:pad_h=1080" \
        1920 1080 320 180 1280 720 64 512 512 4 1
}

run_scale_pad() {
    run_synthetic scale-pad nv12 yuv420p 640 480 "w=1440:h=1080:pad_w=1920:pad_h=1080" \
        1920 1080 240 0 1440 1080 16 128 128 1 0
}

run_same_size() {
    run_synthetic same-size nv12 yuv420p 720 480 "w=720:h=404:pad_w=720:pad_h=480" \
        720 480 0 38 720 404 16 128 128 1 0
}

run_odd_offset() {
    local log="$logdir/odd-offset.log"
    run_synthetic odd-offset nv12 yuv420p 1280 720 "pad_w=1920:pad_h=1080:pad_x=101:pad_y=41" \
        1920 1080 100 40 1280 720 16 128 128 1 1 || return
    if ! grep -q "Aligning pad geometry to the chroma grid" "$log"; then
        echo "      (note: no 'Aligning pad geometry' line in the log; placement was still correct)"
    fi
}

# Border colour must agree with the software pad filter on a link tagged bt709/tv.
run_nv12_offset_color() {
    local name=nv12-offset-color
    local reflog="$logdir/$name.ref.log" refstats="$logdir/$name.ref.top"
    ff -nostdin -hide_banner -nostats -loglevel error \
        -f lavfi -i "testsrc2=size=1280x720:rate=25:duration=0.2" \
        -vf "format=nv12,setparams=colorspace=bt709:range=tv,pad=1920:1080:100:40:color=red,format=yuv420p,crop=1920:40:0:0,signalstats,metadata=print:file=$name.ref.top" \
        -f null - >"$reflog" 2>&1 || { report_skip "$name" "software reference failed" "$reflog"; return; }
    local ey eu ev
    ey="$(stat_mean "$refstats" YAVG)"; eu="$(stat_mean "$refstats" UAVG)"; ev="$(stat_mean "$refstats" VAVG)"
    run_synthetic "$name" nv12 yuv420p 1280 720 "pad_w=1920:pad_h=1080:pad_x=100:pad_y=40:pad_color=red" \
        1920 1080 100 40 1280 720 "$ey" "$eu" "$ev" 2 1 "setparams=colorspace=bt709:range=tv"
}

# --- decode cases -----------------------------------------------------------

run_decoded_1088() {
    local name=decoded-1088 log="$logdir/decoded-1088.log" bottom="$logdir/decoded-1088.bottom" ok=1
    [ -f "$sample" ] || { report_skip "$name" "sample not found: $sample"; return; }
    ff "${common[@]}" \
        -hwaccel qsv -hwaccel_device hw -hwaccel_output_format qsv -i "$(ffpath "$sample")" \
        -filter_complex "[0:v]vpp_qsv=pad_w=1920:pad_h=1200,hwdownload,format=nv12,format=yuv420p,split[a][info];[a]crop=1920:60:0:1140,signalstats,metadata=print:file=decoded-1088.bottom[ta];[info]showinfo[ti]" \
        -map "[ta]" -f null - -map "[ti]" -f null - >"$log" 2>&1
    local rc=$?
    if [ $rc -ne 0 ]; then
        if grep -qiE "hwaccel|Failed setup for format qsv" "$log" && ! grep -q "Parsed_vpp_qsv" "$log"; then
            report_skip "$name" "QSV decode unavailable" "$log"
        else
            report_fail "$name" "ffmpeg exited $rc: $(grep -iE 'error|MFX' "$log" | tail -1)"
        fi
        return
    fi
    local size; size="$(showinfo_size "$log")"
    [ "$size" = "1920x1200" ] || { report_fail "$name" "output is ${size:-<none>}, expected 1920x1200"; return; }
    check_border "$name" "$bottom" "bottom (rows 1140-1199, below the 1088-row decoder surface)" 16 128 128 1 || ok=0
    read -r nframes badpts <<<"$(showinfo_pts_check "$log")"
    if [ "$nframes" -lt 40 ] || [ "$badpts" -ne 0 ]; then
        report_fail "$name" "$nframes output frames, $badpts non-increasing pts"; ok=0
    fi
    [ $ok -eq 1 ] && report_pass "$name" "1920x1200, bottom strip $(stat_mean "$bottom" YAVG)/$(stat_mean "$bottom" UAVG)/$(stat_mean "$bottom" VAVG), $nframes frames, pts monotonic"
}

run_pipeline() {
    local name=pipeline log="$logdir/pipeline.log"
    for f in "$sample" "$overlay"; do
        [ -f "$f" ] || { report_skip "$name" "sample not found: $f"; return; }
    done
    ff "${common[@]}" \
        -hwaccel qsv -hwaccel_device hw -hwaccel_output_format qsv -i "$(ffpath "$sample")" -i "$(ffpath "$overlay")" \
        -filter_complex "[0:v]vpp_qsv=w=1280:h=720:pad_w=1920:pad_h=1080,setsar=1[p];[1:v]format=nv12,hwupload=extra_hw_frames=16[wm];[p][wm]overlay_qsv=x=20:y=20[o]" \
        -map "[o]" -c:v h264_qsv -f null - >"$log" 2>&1
    local rc=$?
    if [ $rc -ne 0 ]; then
        if grep -qiE "h264_qsv|Unknown encoder" "$log" && ! grep -q "Parsed_vpp_qsv" "$log"; then
            report_skip "$name" "QSV encode unavailable" "$log"
        else
            report_fail "$name" "ffmpeg exited $rc: $(grep -iE 'error|MFX' "$log" | tail -1)"
        fi
        return
    fi
    local size
    size="$(awk '/^Output #/ { out = 1 } out && /^ *Stream #.*Video:/ { if (match($0, /[0-9]+x[0-9]+/)) { print substr($0, RSTART, RLENGTH); exit } }' "$log")"
    [ "$size" = "1920x1080" ] || { report_fail "$name" "encoder input is ${size:-<none>}, expected 1920x1080"; return; }
    report_pass "$name" "decode -> vpp_qsv scale+pad -> overlay_qsv -> h264_qsv, $size"
}

# --- probes -----------------------------------------------------------------

# Picture-region YAVG for a vpp_qsv argument string. probe_yavg <name> <swfmt>
# <planar> <source filters> <vpp args>; prints "nan" when ffmpeg fails and
# "rejected" when vpp_qsv refused the combination at configuration.
probe_yavg() {
    local name="$1" swfmt="$2" planar="$3" srcfilters="$4" vppargs="$5"
    local log="$logdir/$name.log" stats="$logdir/$name.stats"
    ff "${common[@]}" -f lavfi -i "testsrc2=size=1280x720:rate=25:duration=0.4" \
        -vf "format=$swfmt${srcfilters:+,$srcfilters},hwupload,vpp_qsv=$vppargs,hwdownload,format=$swfmt,format=$planar,crop=1280:720:(iw-1280)/2:(ih-720)/2,signalstats,metadata=print:file=$name.stats" \
        -f null - >"$log" 2>&1
    if [ $? -ne 0 ]; then
        grep -q "composition mode" "$log" && echo rejected || echo nan
        return
    fi
    stat_mean "$stats" YAVG
}

# Three-way comparison: the padded result equals the unpadded processed
# result (honoured), equals the unprocessed source (ignored), or neither.
probe_verdict() {
    local what="$1" plain="$2" nopad="$3" padded="$4"
    if [ "$padded" = rejected ]; then echo "$what + pad REJECTED at configuration (0010)"
    elif within "$padded" "$nopad" 2; then echo "$what HONOURED in composition mode"
    elif within "$padded" "$plain" 2; then echo "$what IGNORED in composition mode"
    else echo "inconclusive"; fi
}

run_procamp_probe() {
    local plain nopad padded
    plain="$(probe_yavg procamp-plain nv12 yuv420p "" "w=iw:h=ih")"
    nopad="$(probe_yavg procamp-nopad nv12 yuv420p "" "procamp=1:brightness=100")"
    padded="$(probe_yavg procamp-pad nv12 yuv420p "" "pad_w=1920:pad_h=1080:procamp=1:brightness=100")"
    report_info procamp-probe "picture YAVG plain=$plain procamp=$nopad procamp+pad=$padded: $(probe_verdict procamp "$plain" "$nopad" "$padded")"
}

# tv -> pc range conversion moves black from 16 to 0 and stretches everything else.
run_range_probe() {
    local plain nopad padded src="setparams=range=tv"
    plain="$(probe_yavg range-plain nv12 yuv420p "$src" "w=iw:h=ih")"
    nopad="$(probe_yavg range-nopad nv12 yuv420p "$src" "out_range=pc")"
    padded="$(probe_yavg range-pad nv12 yuv420p "$src" "pad_w=1920:pad_h=1080:out_range=pc")"
    if within "$plain" "$nopad" 2; then
        report_info range-probe "picture YAVG tv=$plain out_range=pc=$nopad pc+pad=$padded: out_range=pc did not change the picture even without padding on this runtime; inconclusive"
        return
    fi
    report_info range-probe "picture YAVG tv=$plain out_range=pc=$nopad pc+pad=$padded: $(probe_verdict "colour range conversion" "$plain" "$nopad" "$padded")"
}

# Picture-region YAVG of the decoded HDR sample after a vpp_qsv argument
# string (P010 in and out, so 10-bit numbers). The picture is 1920x1080; with
# padding it is cropped back out of the centre of the canvas.
probe_yavg_hdr() {
    local name="$1" vppargs="$2"
    local log="$logdir/$name.log" stats="$logdir/$name.stats"
    ff "${common[@]}" -hwaccel qsv -hwaccel_device hw -hwaccel_output_format qsv \
        -i "$(ffpath "$hdr_sample")" -an \
        -vf "vpp_qsv=$vppargs,hwdownload,format=p010le,format=yuv420p10le,crop=1920:1080:(iw-1920)/2:(ih-1080)/2,signalstats,metadata=print:file=$name.stats" \
        -f null - >"$log" 2>&1
    if [ $? -ne 0 ]; then
        grep -q "composition mode" "$log" && echo rejected || echo nan
        return
    fi
    stat_mean "$stats" YAVG
}

# HDR10 (PQ, mastering display 1000 nits, MaxCLL 1000) tonemapped to BT.709:
# the sample spans Y 42..966 (10-bit), so a real tonemap moves the mean.
run_tonemap_probe() {
    [ -f "$hdr_sample" ] || { report_info tonemap-probe "HDR sample not found: $hdr_sample"; return; }
    local plain nopad padded
    local tm="tonemap=1:out_color_transfer=bt709:out_color_primaries=bt709:out_color_matrix=bt709"
    plain="$(probe_yavg_hdr tonemap-plain "w=iw:h=ih")"
    nopad="$(probe_yavg_hdr tonemap-nopad "$tm")"
    padded="$(probe_yavg_hdr tonemap-pad "pad_w=2560:pad_h=1440:$tm")"
    if [ "$plain" = nan ] || [ "$nopad" = nan ]; then
        report_info tonemap-probe "decode or tonemap failed (plain=$plain tonemap=$nopad); see $logdir/tonemap-*.log"
        return
    fi
    if within "$plain" "$nopad" 2; then
        report_info tonemap-probe "picture YAVG hdr=$plain tonemap=$nopad: tonemapping did not change the picture even without padding; inconclusive"
        return
    fi
    report_info tonemap-probe "picture YAVG hdr=$plain tonemap=$nopad tonemap+pad=$padded: $(probe_verdict tonemapping "$plain" "$nopad" "$padded")"
}

run_framerate_probe() {
    local log="$logdir/framerate-probe.log"
    ff "${common[@]}" -f lavfi -i "testsrc2=size=1280x720:rate=25:duration=1" \
        -vf "format=nv12,hwupload,vpp_qsv=pad_w=1920:pad_h=1080:framerate=50,hwdownload,format=nv12,showinfo" \
        -fps_mode passthrough -f null - >"$log" 2>&1 || { report_info framerate-probe "ffmpeg failed: $(grep -iE 'error|MFX' "$log" | tail -1)"; return; }
    read -r nframes badpts <<<"$(showinfo_pts_check "$log")"
    local verdict="inconclusive"
    [ "$nframes" -ge 48 ] && verdict="framerate conversion HONOURED in composition mode"
    [ "$nframes" -le 26 ] && verdict="framerate conversion IGNORED in composition mode"
    report_info framerate-probe "25 fps x 1 s with framerate=50 + pad gave $nframes frames ($badpts bad pts): $verdict"
}

echo "ffmpeg:  $FFMPEG"
echo "version: $("$FFMPEG" -version 2>/dev/null | head -1)"
echo "device:  $devspec"
run_probe_device
echo

for case in $CASES; do
    case "$case" in
        nv12-center)        run_nv12_center ;;
        nv12-offset-color)  run_nv12_offset_color ;;
        p010)               run_p010 ;;
        scale-pad)          run_scale_pad ;;
        same-size)          run_same_size ;;
        odd-offset)         run_odd_offset ;;
        decoded-1088)       run_decoded_1088 ;;
        pipeline)           run_pipeline ;;
        procamp-probe)      run_procamp_probe ;;
        framerate-probe)    run_framerate_probe ;;
        range-probe)        run_range_probe ;;
        tonemap-probe)      run_tonemap_probe ;;
        *) echo "unknown case: $case" >&2; exit 2 ;;
    esac
done

echo
echo "$pass passed, $fail failed, $skip skipped"

[ $fail -gt 0 ] && exit 1
[ $pass -eq 0 ] && exit 77
exit 0

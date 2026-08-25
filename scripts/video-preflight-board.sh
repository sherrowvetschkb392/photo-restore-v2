#!/usr/bin/env bash
# Read-only RK3588 video capability inventory. This script must not install,
# remove, start, stop or reconfigure anything on the board.

set -u
export LC_ALL=C LANG=C

PROJECT_ROOT="${1:-/userdata/photo-restore-v2}"

section() {
    printf '%s\n' "---SECTION:$1---"
}

command_path() {
    if command -v "$1" >/dev/null 2>&1; then
        command -v "$1"
    else
        printf 'missing\n'
    fi
}

first_line() {
    "$@" 2>/dev/null | sed -n '1p' || true
}

section PLATFORM
printf 'architecture=%s\n' "$(uname -m)"
printf 'kernel=%s\n' "$(uname -r)"
printf 'hostname=%s\n' "$(hostname)"
printf 'user=%s\n' "$(id -un)"
printf 'groups=%s\n' "$(id -Gn | tr ' ' ',')"
if [ -r /etc/os-release ]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    printf 'os_id=%s\n' "${ID:-unknown}"
    printf 'os_version=%s\n' "${VERSION_ID:-unknown}"
    printf 'os_pretty=%s\n' "${PRETTY_NAME:-unknown}"
else
    printf 'os_id=unknown\n'
    printf 'os_version=unknown\n'
    printf 'os_pretty=unknown\n'
fi

section TOOLS
for tool in ffmpeg ffprobe gst-launch-1.0 gst-inspect-1.0 v4l2-ctl vainfo modetest; do
    printf '%s_path=%s\n' "$(printf '%s' "${tool}" | tr '-' '_')" "$(command_path "${tool}")"
done
if command -v ffmpeg >/dev/null 2>&1; then
    printf 'ffmpeg_version=%s\n' "$(first_line ffmpeg -version)"
else
    printf 'ffmpeg_version=missing\n'
fi
if command -v ffprobe >/dev/null 2>&1; then
    printf 'ffprobe_version=%s\n' "$(first_line ffprobe -version)"
else
    printf 'ffprobe_version=missing\n'
fi
if command -v gst-launch-1.0 >/dev/null 2>&1; then
    printf 'gstreamer_version=%s\n' "$(first_line gst-launch-1.0 --version)"
else
    printf 'gstreamer_version=missing\n'
fi

section FFMPEG_CONFIGURATION
if command -v ffmpeg >/dev/null 2>&1; then
    ffmpeg -version 2>/dev/null | sed -n '1,4p' || true
else
    printf 'unavailable\n'
fi

section FFMPEG_HWACCELS
if command -v ffmpeg >/dev/null 2>&1; then
    ffmpeg -hide_banner -hwaccels 2>/dev/null | sed '/^[[:space:]]*$/d' || true
else
    printf 'unavailable\n'
fi

section FFMPEG_DECODERS
if command -v ffmpeg >/dev/null 2>&1; then
    ffmpeg -hide_banner -decoders 2>/dev/null \
        | grep -Ei '(^|[[:space:]])(h264|hevc|vp8|vp9|av1|mpeg2video|mjpeg|.*rkmpp.*|.*v4l2m2m.*)([[:space:]]|$)' \
        || true
else
    printf 'unavailable\n'
fi

section FFMPEG_ENCODERS
if command -v ffmpeg >/dev/null 2>&1; then
    ffmpeg -hide_banner -encoders 2>/dev/null \
        | grep -Ei '(^|[[:space:]])(h264|hevc|vp8|vp9|av1|mjpeg|.*rkmpp.*|.*v4l2m2m.*)([[:space:]]|$)' \
        || true
else
    printf 'unavailable\n'
fi

section FFMPEG_FILTERS
if command -v ffmpeg >/dev/null 2>&1; then
    ffmpeg -hide_banner -filters 2>/dev/null \
        | grep -Ei '(^|[[:space:]])(minterpolate|scdet|select|scale|scale_rkrga|libvmaf|ssim|psnr|framestep)([[:space:]]|$)' \
        || true
else
    printf 'unavailable\n'
fi

section DEVICES
for device in /dev/mpp_service /dev/rga /dev/dri/renderD128 /dev/dri/renderD129 /dev/mali0 /dev/rknpu; do
    if [ -e "${device}" ]; then
        readable=false
        writable=false
        [ -r "${device}" ] && readable=true
        [ -w "${device}" ] && writable=true
        printf '%s|present|readable=%s|writable=%s\n' "${device}" "${readable}" "${writable}"
    else
        printf '%s|missing|readable=false|writable=false\n' "${device}"
    fi
done
found_video=false
for device in /dev/video*; do
    [ -e "${device}" ] || continue
    found_video=true
    readable=false
    writable=false
    [ -r "${device}" ] && readable=true
    [ -w "${device}" ] && writable=true
    printf '%s|present|readable=%s|writable=%s\n' "${device}" "${readable}" "${writable}"
done
if [ "${found_video}" = false ]; then
    printf '/dev/video*|missing|readable=false|writable=false\n'
fi

section V4L2_DEVICES
if command -v v4l2-ctl >/dev/null 2>&1; then
    v4l2-ctl --list-devices 2>/dev/null || printf 'unavailable\n'
else
    printf 'v4l2_ctl=missing\n'
fi

section GSTREAMER_PLUGINS
if command -v gst-inspect-1.0 >/dev/null 2>&1; then
    for plugin in mppvideodec mpph264enc mpph265enc rkv4l2h264enc rkv4l2h265enc; do
        if GST_REGISTRY_UPDATE=no gst-inspect-1.0 "${plugin}" >/dev/null 2>&1; then
            printf '%s=available\n' "${plugin}"
        else
            printf '%s=missing\n' "${plugin}"
        fi
    done
else
    printf 'gst_inspect=missing\n'
fi

section PACKAGES
if command -v dpkg-query >/dev/null 2>&1; then
    dpkg-query -W -f='${Package}|${Version}\n' 2>/dev/null \
        | grep -Ei '(^|[-])(ffmpeg|gstreamer|mpp|rockchip|rga|v4l|drm)' \
        | sort \
        || true
else
    printf 'dpkg_query=missing\n'
fi

section KERNEL_MODULES
if command -v lsmod >/dev/null 2>&1; then
    lsmod | grep -Ei '(^|_)(rga|mpp|vcodec|hantro|rockchip|rknpu|drm)' || true
else
    printf 'lsmod=missing\n'
fi

section PYTHON
PYTHON="${PROJECT_ROOT}/venv/bin/python"
if [ -x "${PYTHON}" ]; then
    printf 'python_path=%s\n' "${PYTHON}"
    "${PYTHON}" -c 'import importlib.util, platform, sys; print("python_version=" + platform.python_version()); print("python_architecture=" + platform.machine()); spec=importlib.util.find_spec("cv2"); print("opencv_available=" + str(spec is not None).lower()); print("executable=" + sys.executable)' 2>/dev/null || printf 'python_probe=failed\n'
    "${PYTHON}" -c 'import cv2; print("opencv_version=" + cv2.__version__)' 2>/dev/null || printf 'opencv_version=missing\n'
else
    printf 'python_path=missing\n'
    printf 'python_probe=unavailable\n'
fi

section RESOURCES
awk '/MemTotal:/ {printf "memory_total_bytes=%.0f\n", $2 * 1024} /MemAvailable:/ {printf "memory_available_bytes=%.0f\n", $2 * 1024} /SwapTotal:/ {printf "swap_total_bytes=%.0f\n", $2 * 1024}' /proc/meminfo
if df -Pk "${PROJECT_ROOT}" >/dev/null 2>&1; then
    df -Pk "${PROJECT_ROOT}" | awk 'NR==2 {printf "filesystem_total_bytes=%.0f\n", $2 * 1024; printf "filesystem_used_bytes=%.0f\n", $3 * 1024; printf "filesystem_available_bytes=%.0f\n", $4 * 1024; print "filesystem_used_percent=" $5}'
else
    printf 'filesystem_probe=failed\n'
fi
printf 'uptime_seconds=%s\n' "$(cut -d. -f1 /proc/uptime)"
if [ -r /sys/kernel/debug/rknpu/load ]; then
    printf 'npu_load=%s\n' "$(tr '\n' ' ' < /sys/kernel/debug/rknpu/load | sed 's/[[:space:]][[:space:]]*/ /g')"
elif command -v sudo >/dev/null 2>&1 && sudo -n test -r /sys/kernel/debug/rknpu/load 2>/dev/null; then
    printf 'npu_load=%s\n' "$(sudo -n cat /sys/kernel/debug/rknpu/load 2>/dev/null | tr '\n' ' ' | sed 's/[[:space:]][[:space:]]*/ /g')"
else
    printf 'npu_load=unavailable\n'
fi

section THERMAL
for zone in /sys/class/thermal/thermal_zone*; do
    [ -r "${zone}/temp" ] || continue
    zone_type="$(cat "${zone}/type" 2>/dev/null || basename "${zone}")"
    zone_temp="$(cat "${zone}/temp" 2>/dev/null || printf unknown)"
    printf '%s=%s\n' "${zone_type}" "${zone_temp}"
done

section SERVICES
for service in photo-restore-api.service cloudflared.service; do
    safe_name="$(printf '%s' "${service}" | tr '.-' '__')"
    if command -v systemctl >/dev/null 2>&1; then
        printf '%s_active=%s\n' "${safe_name}" "$(systemctl is-active "${service}" 2>/dev/null || true)"
        printf '%s_enabled=%s\n' "${safe_name}" "$(systemctl is-enabled "${service}" 2>/dev/null || true)"
    else
        printf '%s_active=unavailable\n' "${safe_name}"
        printf '%s_enabled=unavailable\n' "${safe_name}"
    fi
done

section PROCESSES
printf 'restore_worker_count=%s\n' "$(pgrep -fc "^${PROJECT_ROOT}/venv/bin/python ${PROJECT_ROOT}/app/worker/restore_image.py " 2>/dev/null || true)"
printf 'ffmpeg_process_count=%s\n' "$(pgrep -fc '(^|/)ffmpeg([[:space:]]|$)' 2>/dev/null || true)"
printf 'video_worker_count=%s\n' "$(pgrep -fc "${PROJECT_ROOT}.*video" 2>/dev/null || true)"

printf '%s\n' '---END---'

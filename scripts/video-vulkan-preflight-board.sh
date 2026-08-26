#!/usr/bin/env bash
# Read-only Vulkan/NCNN capability inventory for existing pre-trained video
# models. This script never installs packages or changes services.

set -u
export LC_ALL=C LANG=C

section() { printf '%s\n' "---SECTION:$1---"; }
command_path() { command -v "$1" 2>/dev/null || printf 'missing\n'; }

section PLATFORM
printf 'architecture=%s\n' "$(uname -m)"
printf 'kernel=%s\n' "$(uname -r)"

section DEVICES
for device in /dev/mali0 /dev/dri/renderD128 /dev/dri/renderD129; do
    if [ -e "$device" ]; then
        readable=false; writable=false
        [ -r "$device" ] && readable=true
        [ -w "$device" ] && writable=true
        printf '%s|present|readable=%s|writable=%s\n' "$device" "$readable" "$writable"
    else
        printf '%s|missing|readable=false|writable=false\n' "$device"
    fi
done

section TOOLS
printf 'vulkaninfo_path=%s\n' "$(command_path vulkaninfo)"
printf 'glslc_path=%s\n' "$(command_path glslc)"
printf 'cmake_path=%s\n' "$(command_path cmake)"
printf 'ninja_path=%s\n' "$(command_path ninja)"
printf 'git_path=%s\n' "$(command_path git)"
printf 'gxx_path=%s\n' "$(command_path g++)"
printf 'make_path=%s\n' "$(command_path make)"

section VULKAN_LIBRARIES
if command -v ldconfig >/dev/null 2>&1; then
    ldconfig -p 2>/dev/null | grep -Ei 'libvulkan|libmali' || true
elif [ -x /sbin/ldconfig ]; then
    /sbin/ldconfig -p 2>/dev/null | grep -Ei 'libvulkan|libmali' || true
else
    printf 'ldconfig=missing\n'
fi
find /usr/lib /lib -maxdepth 5 -type f \( -iname 'libvulkan*.so*' -o -iname 'libmali*.so*' \) -print 2>/dev/null || true

section VULKAN_ICD
found=false
for path in /etc/vulkan/icd.d/*.json /usr/share/vulkan/icd.d/*.json /usr/local/share/vulkan/icd.d/*.json; do
    [ -f "$path" ] || continue
    found=true
    printf 'icd=%s\n' "$path"
    sed -n '1,80p' "$path" 2>/dev/null || true
done
[ "$found" = true ] || printf 'icd=missing\n'

section VULKANINFO
if command -v vulkaninfo >/dev/null 2>&1; then
    if timeout 15s vulkaninfo --summary 2>&1; then
        printf 'vulkaninfo_exit_code=0\n'
    else
        code=$?
        printf 'vulkaninfo_exit_code=%s\n' "$code"
    fi
else
    printf 'vulkaninfo_exit_code=missing\n'
fi

section GPU_PACKAGES
if command -v dpkg-query >/dev/null 2>&1; then
    dpkg-query -W -f='${Package}|${Version}\n' 2>/dev/null \
        | grep -Ei '(vulkan|mali|panfrost|panfork|mesa|drm)' \
        | sort || true
else
    printf 'dpkg_query=missing\n'
fi

section EXISTING_NCNN
for root in /usr/local/bin /usr/bin /userdata/photo-restore-v2/bin /userdata/photo-restore-v2/packages; do
    [ -d "$root" ] || continue
    find "$root" -maxdepth 2 -type f \( -iname '*ncnn*' -o -iname '*rife*' -o -iname '*realesrgan*' \) -print 2>/dev/null || true
done

section RESOURCES
awk '/MemAvailable:/ {printf "memory_available_bytes=%.0f\n", $2 * 1024}' /proc/meminfo
df -Pk /userdata 2>/dev/null | awk 'NR==2 {printf "filesystem_available_bytes=%.0f\n", $4 * 1024}'

section PRODUCTION
printf 'api_active=%s\n' "$(systemctl is-active photo-restore-api.service 2>/dev/null || true)"
printf 'tunnel_active=%s\n' "$(systemctl is-active cloudflared.service 2>/dev/null || true)"
printf 'media_worker_count=%s\n' "$(pgrep -fc '/userdata/photo-restore-v2.*(video|rife|ncnn)' 2>/dev/null || true)"

printf '%s\n' '---END---'

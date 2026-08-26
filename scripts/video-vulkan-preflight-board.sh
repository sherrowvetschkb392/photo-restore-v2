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
for tool in vulkaninfo glslc cmake ninja git g++ make; do
    printf '%s_path=%s\n' "$(printf '%s' "$tool" | tr '+-' '__')" "$(command_path "$tool")"
done

section VULKAN_LIBRARIES
if command -v ldconfig >/dev/null 2>&1; then
    ldconfig -p 2>/dev/null | grep -Ei 'libvulkan|libmali' || true
else
    printf 'ldconfig=missing\n'
fi

section VULKAN_ICD
found=false
for path in /etc/vulkan/icd.d/*.json /usr/share/vulkan/icd.d/*.json; do
    [ -f "$path" ] || continue
    found=true
    printf 'icd=%s\n' "$path"
    sed -n '1,80p' "$path" 2>/dev/null || true
done
[ "$found" = true ] || printf 'icd=missing\n'

section VULKANINFO
if command -v vulkaninfo >/dev/null 2>&1; then
    timeout 15s vulkaninfo --summary 2>&1 || printf 'vulkaninfo_status=failed\n'
else
    printf 'vulkaninfo_status=missing\n'
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

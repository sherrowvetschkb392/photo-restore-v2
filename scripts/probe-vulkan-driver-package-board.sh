#!/usr/bin/env bash
# Probe an ARM64 Mali Vulkan driver package from an isolated temporary tree.
# This script never installs packages or changes system driver configuration.

set -u
export LC_ALL=C LANG=C

package_path="${1:-}"
if [ -z "$package_path" ] || [ ! -f "$package_path" ]; then
    printf 'error=package_missing\n' >&2
    exit 2
fi
if ! command -v dpkg-deb >/dev/null 2>&1; then
    printf 'error=dpkg_deb_missing\n' >&2
    exit 3
fi

work_root="$(mktemp -d /tmp/photo-restore-vulkan-package-probe.XXXXXX)"
trap 'rm -rf "$work_root"' EXIT INT TERM
extract_root="$work_root/root"
mkdir -p "$extract_root"

section() { printf '%s\n' "---SECTION:$1---"; }

section PACKAGE
for field in Package Version Architecture Depends Conflicts Breaks Replaces Provides; do
    value="$(dpkg-deb -f "$package_path" "$field" 2>/dev/null || true)"
    printf '%s=%s\n' "$(printf '%s' "$field" | tr '[:upper:]' '[:lower:]')" "$value"
done
printf 'bytes=%s\n' "$(wc -c < "$package_path" | tr -d ' ')"
if command -v sha256sum >/dev/null 2>&1; then sha256sum "$package_path"; fi

architecture="$(dpkg-deb -f "$package_path" Architecture 2>/dev/null || true)"
case "$architecture" in
    arm64|aarch64) ;;
    *) printf 'error=unsupported_architecture:%s\n' "$architecture" >&2; exit 4 ;;
esac

dpkg-deb -x "$package_path" "$extract_root"

section VULKAN_FILES
find "$extract_root" \( -type f -o -type l \) \
    \( -iname '*vulkan*' -o -iname '*mali*.so*' -o -path '*/vulkan/icd.d/*.json' \) \
    -print 2>/dev/null | sort || true

library=""
for candidate in \
    "$extract_root/usr/lib/aarch64-linux-gnu/libmali.so.1" \
    "$extract_root/usr/lib/aarch64-linux-gnu/libmali.so" \
    "$extract_root/lib/aarch64-linux-gnu/libmali.so.1" \
    "$extract_root/lib/aarch64-linux-gnu/libmali.so"; do
    if [ -e "$candidate" ]; then library="$(readlink -f "$candidate")"; break; fi
done
if [ -z "$library" ]; then
    library="$(find -L "$extract_root" -type f -iname 'libmali.so*' -print 2>/dev/null | head -1)"
fi

section SYMBOLS
printf 'library=%s\n' "$library"
symbol_status=missing
if [ -n "$library" ] && [ -f "$library" ]; then
    if command -v readelf >/dev/null 2>&1; then
        readelf -Ws "$library" 2>/dev/null | grep -E 'vk_icdGetInstanceProcAddr|vkGetInstanceProcAddr' || true
        if readelf -Ws "$library" 2>/dev/null | grep -Eq 'vk_icdGetInstanceProcAddr|vkGetInstanceProcAddr'; then symbol_status=present; fi
    elif command -v nm >/dev/null 2>&1; then
        nm -D "$library" 2>/dev/null | grep -E 'vk_icdGetInstanceProcAddr|vkGetInstanceProcAddr' || true
        if nm -D "$library" 2>/dev/null | grep -Eq 'vk_icdGetInstanceProcAddr|vkGetInstanceProcAddr'; then symbol_status=present; fi
    elif strings "$library" 2>/dev/null | grep -Eq 'vk_icdGetInstanceProcAddr|vkGetInstanceProcAddr'; then
        symbol_status=present
    fi
fi
printf 'vulkan_entrypoint=%s\n' "$symbol_status"

section PRIVATE_RUNTIME
runtime_status=blocked
if [ "$symbol_status" != present ]; then
    printf 'private_probe=skipped_missing_entrypoint\n'
elif ! command -v vulkaninfo >/dev/null 2>&1; then
    printf 'private_probe=skipped_vulkaninfo_missing\n'
else
    icd_file="$(find "$extract_root" -type f -path '*/vulkan/icd.d/*.json' -print 2>/dev/null | head -1)"
    if [ -z "$icd_file" ]; then
        icd_file="$work_root/candidate_icd.json"
        printf '{"file_format_version":"1.0.0","ICD":{"library_path":"%s","api_version":"1.2.0"}}\n' "$library" > "$icd_file"
    fi
    library_path="$(find "$extract_root" -type d \( -path '*lib*' -o -path '*lib*/*' \) -print 2>/dev/null | paste -sd: -)"
    output="$(LD_LIBRARY_PATH="$library_path${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" VK_ICD_FILENAMES="$icd_file" timeout 20s vulkaninfo --summary 2>&1)"
    code=$?
    printf '%s\n' "$output"
    printf 'vulkaninfo_exit_code=%s\n' "$code"
    if [ "$code" -eq 0 ] && printf '%s\n' "$output" | grep -Eq 'deviceName|GPU id' \
        && ! printf '%s\n' "$output" | grep -Eq 'ERROR_INCOMPATIBLE_DRIVER|Cannot create Vulkan instance'; then
        runtime_status=passed
        printf 'private_probe=passed\n'
    else
        printf 'private_probe=failed\n'
    fi
fi

section PRODUCTION
printf 'api_active=%s\n' "$(systemctl is-active photo-restore-api.service 2>/dev/null || true)"
printf 'tunnel_active=%s\n' "$(systemctl is-active cloudflared.service 2>/dev/null || true)"

printf '%s\n' '---END---'
if [ "$runtime_status" = passed ]; then
    printf '%s\n' 'RESULT=PASS_PRIVATE_VULKAN_DRIVER_PACKAGE_PROBE'
    exit 0
fi
printf '%s\n' 'RESULT=BLOCKED_PRIVATE_VULKAN_DRIVER_PACKAGE_PROBE'
exit 10

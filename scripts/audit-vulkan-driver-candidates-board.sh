#!/usr/bin/env bash
# Read-only RK3588 Vulkan driver/package candidate audit. No apt update,
# package installation, removal, service change or firmware write is allowed.

set -u
export LC_ALL=C LANG=C

section() { printf '%s\n' "---SECTION:$1---"; }

section PLATFORM
printf 'architecture=%s\n' "$(uname -m)"
printf 'kernel=%s\n' "$(uname -r)"
if [ -r /etc/os-release ]; then . /etc/os-release; printf 'os=%s %s\n' "${ID:-unknown}" "${VERSION_ID:-unknown}"; fi

section BOARD_IDENTITY
for path in /proc/device-tree/model /sys/firmware/devicetree/base/model; do
    [ -r "$path" ] || continue
    printf 'path=%s\n' "$path"
    tr '\0' '\n' < "$path" 2>/dev/null || true
done
for path in /proc/device-tree/compatible /sys/firmware/devicetree/base/compatible; do
    [ -r "$path" ] || continue
    printf 'compatible_path=%s\n' "$path"
    tr '\0' '\n' < "$path" 2>/dev/null || true
done
printf 'hostname=%s\n' "$(hostname 2>/dev/null || true)"
for path in /etc/armbian-release /etc/board-release /etc/rk-release /etc/issue; do
    [ -r "$path" ] || continue
    printf 'release_file=%s\n' "$path"
    sed -n '1,80p' "$path" 2>/dev/null || true
done

section BOOT_FIRMWARE
printf 'uname=%s\n' "$(uname -a)"
for path in /boot/extlinux/extlinux.conf /boot/uEnv.txt /boot/armbianEnv.txt; do
    [ -r "$path" ] || continue
    printf 'boot_config=%s\n' "$path"
    sed -n '1,160p' "$path" 2>/dev/null || true
done
dpkg-query -W -f='${Package}|${Version}|${db:Status-Status}\n' 2>/dev/null \
    | grep -Ei '(linux-image|linux-dtb|linux-u-boot|u-boot|rk3588|rockchip)' \
    | sort || true

section GPU_DEVICE_TREE
for path in /proc/device-tree/gpu/compatible /sys/firmware/devicetree/base/gpu/compatible; do
    [ -r "$path" ] || continue
    printf 'path=%s\n' "$path"
    tr '\0' '\n' < "$path" 2>/dev/null || true
done

section GPU_KERNEL
if command -v lsmod >/dev/null 2>&1; then lsmod | grep -Ei '(^|_)(mali|panfrost|gpu)' || true; fi
dmesg 2>/dev/null | grep -Ei 'mali|panfrost|gpu' | tail -100 || true

section INSTALLED_MALI_PACKAGE
dpkg-query -W -f='package=${Package}\nversion=${Version}\narchitecture=${Architecture}\nstatus=${db:Status-Status}\ndepends=${Depends}\n' \
    libmali-valhall-g610-g13p0-x11-gbm 2>/dev/null || printf 'package=missing\n'

section INSTALLED_MALI_FILES
dpkg -L libmali-valhall-g610-g13p0-x11-gbm 2>/dev/null || true

section INSTALLED_GPU_PACKAGES
dpkg-query -W -f='${Package}|${Version}|${db:Status-Status}\n' 2>/dev/null \
    | grep -Ei '(mali|vulkan|panfrost|panvk|mesa|drm|opencl)' \
    | sort || true

section APT_SOURCES
grep -RhE '^[[:space:]]*deb[[:space:]]' /etc/apt/sources.list /etc/apt/sources.list.d 2>/dev/null || true

section APT_SEARCH
apt-cache search 'mali|vulkan|panfrost|panvk' 2>/dev/null \
    | grep -Ei '(mali|vulkan|panfrost|panvk|g610|valhall)' \
    | sort || true

section APT_PACKAGE_NAMES
apt-cache pkgnames 2>/dev/null \
    | grep -Ei '(libmali|mali.*g610|g610.*mali|panvk|mesa-vulkan|vulkan-driver)' \
    | sort -u || true

section APT_POLICY
candidates="$(apt-cache pkgnames 2>/dev/null | grep -Ei '(libmali|mali.*g610|g610.*mali|panvk|mesa-vulkan|vulkan-driver)' | sort -u | tr '\n' ' ')"
if [ -n "$candidates" ]; then
    # shellcheck disable=SC2086
    apt-cache policy $candidates 2>/dev/null || true
else
    printf 'candidate_packages=none\n'
fi

section APT_VENDOR_REPOSITORY_VERSIONS
vendor_candidates="$(apt-cache pkgnames 2>/dev/null | grep -Ei '(libmali|mali.*g610|g610.*mali)' | grep -Eiv 'dbgsym|dbg|dev' | sort -u)"
if [ -n "$vendor_candidates" ]; then
    printf '%s\n' "$vendor_candidates" | while IFS= read -r package; do
        [ -n "$package" ] || continue
        apt-cache madison "$package" 2>/dev/null | sed "s/^[[:space:]]*/${package}|/" || true
    done
else
    printf 'vendor_repository_packages=none\n'
fi

section LOCAL_VENDOR_ARTIFACTS
find /var/cache/apt/archives /userdata /opt /usr/local/src -maxdepth 5 -type f \
    \( -iname '*libmali*.deb' -o -iname '*g610*.deb' -o -iname '*mali*vulkan*' \) \
    -print 2>/dev/null | sort || true

section BUILD_TOOL_POLICY
apt-cache policy g++ make ninja-build glslc glslang-tools 2>/dev/null || true

section BUILD_TOOL_SIMULATION
apt-get -s --no-remove install g++ make ninja-build glslang-tools 2>&1 || true

section MESA_VULKAN_SIMULATION
if apt-cache show mesa-vulkan-drivers >/dev/null 2>&1; then
    apt-get -s --no-remove install mesa-vulkan-drivers 2>&1 || true
else
    printf 'mesa_vulkan_drivers=unavailable\n'
fi

section PRODUCTION
printf 'api_active=%s\n' "$(systemctl is-active photo-restore-api.service 2>/dev/null || true)"
printf 'tunnel_active=%s\n' "$(systemctl is-active cloudflared.service 2>/dev/null || true)"
printf 'media_worker_count=%s\n' "$(pgrep -fc '/userdata/photo-restore-v2.*(video|rife|ncnn)' 2>/dev/null || true)"

printf '%s\n' '---END---'

#!/bin/sh
# Read-only MNN/OpenCL build and runtime inventory for the existing board.
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

section PLATFORM
printf 'architecture=%s\n' "$(uname -m)"
printf 'kernel=%s\n' "$(uname -r)"
if [ -r /etc/os-release ]; then
    . /etc/os-release
    printf 'os_id=%s\n' "${ID:-unknown}"
    printf 'os_version=%s\n' "${VERSION_ID:-unknown}"
    printf 'os_pretty=%s\n' "${PRETTY_NAME:-unknown}"
fi

section TOOLS
for tool in git cmake make ninja gcc g++ clang pkg-config python3 patchelf readelf; do
    safe_name="$(printf '%s' "$tool" | tr '+-' 'xp')"
    printf '%s_path=%s\n' "$safe_name" "$(command_path "$tool")"
done
for tool in cmake gcc g++ clang python3; do
    if command -v "$tool" >/dev/null 2>&1; then
        safe_name="$(printf '%s' "$tool" | tr '+-' 'xp')"
        printf '%s_version=%s\n' "$safe_name" "$("$tool" --version 2>/dev/null | sed -n '1p')"
    fi
done

section OPENCL
if command -v ldconfig >/dev/null 2>&1; then
    ldconfig -p 2>/dev/null | grep -E 'libOpenCL|libMaliOpenCL|libmali' || true
elif [ -x /sbin/ldconfig ]; then
    /sbin/ldconfig -p 2>/dev/null | grep -E 'libOpenCL|libMaliOpenCL|libmali' || true
fi
for path in /etc/OpenCL/vendors/*.icd /usr/share/OpenCL/vendors/*.icd; do
    [ -f "$path" ] || continue
    printf 'icd=%s|%s\n' "$path" "$(tr '\n' ' ' < "$path")"
done
for path in \
    /usr/include/CL/cl.h \
    /usr/include/CL/opencl.h \
    /usr/local/include/CL/cl.h \
    /usr/local/include/CL/opencl.h; do
    if [ -f "$path" ]; then
        printf 'header=%s\n' "$path"
    fi
done
if command -v pkg-config >/dev/null 2>&1; then
    if pkg-config --exists OpenCL 2>/dev/null; then
        printf 'pkg_config_opencl=true\n'
        printf 'pkg_config_opencl_version=%s\n' "$(pkg-config --modversion OpenCL 2>/dev/null || true)"
    else
        printf 'pkg_config_opencl=false\n'
    fi
else
    printf 'pkg_config_opencl=unavailable\n'
fi

section EXISTING_MNN
found=false
for root in "$PROJECT_ROOT" /usr/local /usr; do
    [ -e "$root" ] || continue
    find "$root" -maxdepth 6 \
        \( -type f -o -type l \) \
        \( -iname 'libMNN.so*' -o -iname 'MNNConvert' -o -iname 'ModuleBasic.out' -o -iname 'testMNNFromOnnx.out' \) \
        -print 2>/dev/null | sort -u
done | while IFS= read -r path; do
    found=true
    printf 'artifact=%s\n' "$path"
done
if ! find "$PROJECT_ROOT" /usr/local /usr -maxdepth 6 \
    \( -type f -o -type l \) \
    \( -iname 'libMNN.so*' -o -iname 'MNNConvert' -o -iname 'ModuleBasic.out' -o -iname 'testMNNFromOnnx.out' \) \
    -print -quit 2>/dev/null | grep -q .; then
    printf 'artifact=none\n'
fi

section APT_METADATA
if command -v apt-cache >/dev/null 2>&1; then
    for package in build-essential cmake ninja-build git ocl-icd-opencl-dev opencl-headers clinfo; do
        if apt-cache show "$package" >/dev/null 2>&1; then
            candidate="$(apt-cache policy "$package" 2>/dev/null | awk '/Candidate:/ {print $2; exit}')"
            installed="$(apt-cache policy "$package" 2>/dev/null | awk '/Installed:/ {print $2; exit}')"
            printf '%s|available=true|installed=%s|candidate=%s\n' "$package" "${installed:-unknown}" "${candidate:-unknown}"
        else
            printf '%s|available=false|installed=unknown|candidate=unknown\n' "$package"
        fi
    done
else
    printf 'apt_cache=unavailable\n'
fi

section RESOURCES
awk '/MemTotal:/ {printf "memory_total_bytes=%.0f\n", $2 * 1024} /MemAvailable:/ {printf "memory_available_bytes=%.0f\n", $2 * 1024} /SwapTotal:/ {printf "swap_total_bytes=%.0f\n", $2 * 1024}' /proc/meminfo
df -Pk "$PROJECT_ROOT" 2>/dev/null | awk 'NR==2 {printf "filesystem_total_bytes=%.0f\n", $2 * 1024; printf "filesystem_available_bytes=%.0f\n", $4 * 1024; print "filesystem_used_percent=" $5}'
printf 'logical_cpus=%s\n' "$(getconf _NPROCESSORS_ONLN 2>/dev/null || printf unknown)"
for zone in /sys/class/thermal/thermal_zone*; do
    [ -r "$zone/temp" ] || continue
    printf 'temperature=%s|%s\n' "$(cat "$zone/type" 2>/dev/null || basename "$zone")" "$(cat "$zone/temp")"
done

section PRODUCTION
for service in photo-restore-api.service cloudflared.service; do
    if command -v systemctl >/dev/null 2>&1; then
        printf '%s|active=%s|enabled=%s\n' "$service" "$(systemctl is-active "$service" 2>/dev/null || true)" "$(systemctl is-enabled "$service" 2>/dev/null || true)"
    fi
done
printf 'media_workers=%s\n' "$(pgrep -fc '/userdata/photo-restore-v2.*([r]estore_image.py|[r]ife|[m]nn)' 2>/dev/null || true)"

printf '%s\n' '---END---'


#!/usr/bin/env bash
set -u

PROJECT_ROOT="/userdata/photo-restore-v2"
REPORT_DIR="${PROJECT_ROOT}/benchmarks"
TIMESTAMP="$(date -u +%Y%m%dT%H%M%SZ)"
REPORT_FILE="${REPORT_DIR}/device-audit-${TIMESTAMP}.txt"

mkdir -p "${REPORT_DIR}"

section() {
    printf '\n## %s\n' "$1"
}

{
    printf '# RK3588 Device Audit\n'
    printf 'generated_at_utc=%s\n' "${TIMESTAMP}"

    section "identity"
    printf 'hostname='; hostname
    printf 'user='; id -un
    printf 'architecture='; uname -m
    printf 'kernel='; uname -r
    printf 'os='; . /etc/os-release && printf '%s\n' "${PRETTY_NAME}"

    section "cpu-memory"
    printf 'cpu_count='; nproc
    free -h
    printf 'swap_bytes='; awk '/SwapTotal/ {print $2 * 1024}' /proc/meminfo

    section "storage"
    df -hT / /userdata 2>&1
    lsblk -o NAME,TYPE,SIZE,FSTYPE,MOUNTPOINT 2>&1

    section "accelerators"
    ls -l /dev/mali0 /dev/dri/renderD128 /dev/dri/renderD129 2>&1
    for device in /dev/dri/renderD128 /dev/dri/renderD129; do
        if [ -e "${device}" ]; then
            printf '%s: ' "${device}"
            udevadm info --query=property --name="${device}" 2>/dev/null \
                | awk -F= '/^ID_PATH=/{print $2}'
        fi
    done

    section "rknn"
    if [ -f /usr/lib/librknnrt.so ]; then
        strings /usr/lib/librknnrt.so \
            | grep -m1 'librknnrt version:' || true
        sha256sum /usr/lib/librknnrt.so
    else
        printf 'librknnrt=missing\n'
    fi
    printf 'rknn_driver_dmesg=' 
    dmesg 2>/dev/null | grep -m1 'Initialized rknpu' || printf 'unavailable\n'

    section "python"
    python3 --version 2>&1
    if [ -x "${PROJECT_ROOT}/venv/bin/python" ]; then
        "${PROJECT_ROOT}/venv/bin/python" -c \
            'import platform,sys; print("venv_arch=" + platform.machine()); print("venv_python=" + sys.version.split()[0]); print("venv_abi=" + sys.implementation.cache_tag)'
    else
        printf 'project_venv=missing\n'
    fi

    section "thermal"
    for zone in /sys/class/thermal/thermal_zone*; do
        [ -r "${zone}/temp" ] || continue
        zone_type="$(cat "${zone}/type" 2>/dev/null || printf unknown)"
        zone_temp="$(cat "${zone}/temp" 2>/dev/null || printf unknown)"
        printf '%s type=%s temp_millicelsius=%s\n' \
            "$(basename "${zone}")" "${zone_type}" "${zone_temp}"
    done
} | tee "${REPORT_FILE}"

printf '\nREPORT_FILE=%s\n' "${REPORT_FILE}"


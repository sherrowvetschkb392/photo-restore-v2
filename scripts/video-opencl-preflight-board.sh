#!/bin/sh
# Read-only OpenCL capability probe. It calls the installed OpenCL loader
# directly and does not install packages, create persistent files or start work.
set -eu

export LC_ALL=C

report_file="$(mktemp /tmp/photo-restore-opencl-report.XXXXXX.json)"
trap 'rm -f "$report_file"' EXIT INT TERM

python3 - "$report_file" <<'PY'
import ctypes
import ctypes.util
import glob
import json
import os
import platform
import subprocess
import sys


def read_text(path):
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as handle:
            return handle.read().strip()
    except OSError:
        return None


def command_output(arguments):
    try:
        return subprocess.check_output(
            arguments, stderr=subprocess.STDOUT, text=True, timeout=10
        ).strip()
    except (OSError, subprocess.SubprocessError):
        return None


report = {
    "schema_version": 1,
    "board_changed": False,
    "platform": {
        "architecture": platform.machine(),
        "kernel": platform.release(),
        "python": platform.python_version(),
    },
    "loader": {},
    "icd_files": [],
    "mali_files": [],
    "opencl": {"call_passed": False, "platforms": [], "error": None},
    "resources": {},
}

loader_candidates = []
resolved_loader = ctypes.util.find_library("OpenCL")
if resolved_loader:
    loader_candidates.append(resolved_loader)
loader_candidates.extend(
    [
        "/usr/lib/aarch64-linux-gnu/libOpenCL.so.1",
        "/usr/lib/aarch64-linux-gnu/libOpenCL.so",
        "/usr/lib/libOpenCL.so.1",
        "/usr/lib/libOpenCL.so",
    ]
)

loader = None
loader_path = None
loader_error = None
for candidate in dict.fromkeys(loader_candidates):
    try:
        loader = ctypes.CDLL(candidate)
        loader_path = candidate
        break
    except OSError as exc:
        loader_error = str(exc)

report["loader"] = {
    "resolved": resolved_loader,
    "loaded": loader is not None,
    "loaded_path": loader_path,
    "error": loader_error if loader is None else None,
}

for pattern in (
    "/etc/OpenCL/vendors/*.icd",
    "/usr/share/OpenCL/vendors/*.icd",
    "/usr/local/etc/OpenCL/vendors/*.icd",
):
    for path in glob.glob(pattern):
        report["icd_files"].append({"path": path, "content": read_text(path)})

for pattern in (
    "/usr/lib/aarch64-linux-gnu/libmali*.so*",
    "/usr/lib/libmali*.so*",
    "/lib/aarch64-linux-gnu/libmali*.so*",
):
    for path in glob.glob(pattern):
        if os.path.isfile(path) or os.path.islink(path):
            report["mali_files"].append(
                {
                    "path": path,
                    "realpath": os.path.realpath(path),
                    "bytes": os.path.getsize(path),
                }
            )

if loader is not None:
    cl_int = ctypes.c_int
    cl_uint = ctypes.c_uint
    cl_ulong = ctypes.c_ulong
    cl_size_t = ctypes.c_size_t
    cl_platform_id = ctypes.c_void_p
    cl_device_id = ctypes.c_void_p

    loader.clGetPlatformIDs.argtypes = [
        cl_uint,
        ctypes.POINTER(cl_platform_id),
        ctypes.POINTER(cl_uint),
    ]
    loader.clGetPlatformIDs.restype = cl_int
    loader.clGetPlatformInfo.argtypes = [
        cl_platform_id,
        cl_uint,
        cl_size_t,
        ctypes.c_void_p,
        ctypes.POINTER(cl_size_t),
    ]
    loader.clGetPlatformInfo.restype = cl_int
    loader.clGetDeviceIDs.argtypes = [
        cl_platform_id,
        cl_ulong,
        cl_uint,
        ctypes.POINTER(cl_device_id),
        ctypes.POINTER(cl_uint),
    ]
    loader.clGetDeviceIDs.restype = cl_int
    loader.clGetDeviceInfo.argtypes = [
        cl_device_id,
        cl_uint,
        cl_size_t,
        ctypes.c_void_p,
        ctypes.POINTER(cl_size_t),
    ]
    loader.clGetDeviceInfo.restype = cl_int

    def get_string(function, handle, parameter):
        size = cl_size_t()
        code = function(handle, parameter, 0, None, ctypes.byref(size))
        if code != 0 or size.value == 0:
            return None
        buffer = ctypes.create_string_buffer(size.value)
        code = function(handle, parameter, size.value, buffer, None)
        if code != 0:
            return None
        return buffer.value.decode("utf-8", errors="replace")

    def get_scalar(function, handle, parameter, scalar_type):
        value = scalar_type()
        code = function(
            handle,
            parameter,
            ctypes.sizeof(value),
            ctypes.byref(value),
            None,
        )
        return value.value if code == 0 else None

    platform_count = cl_uint()
    code = loader.clGetPlatformIDs(0, None, ctypes.byref(platform_count))
    report["opencl"]["cl_get_platform_ids_code"] = code
    report["opencl"]["platform_count"] = platform_count.value
    if code == 0 and platform_count.value:
        platform_array = (cl_platform_id * platform_count.value)()
        code = loader.clGetPlatformIDs(platform_count, platform_array, None)
        if code == 0:
            report["opencl"]["call_passed"] = True
            for platform_id in platform_array:
                platform_record = {
                    "name": get_string(loader.clGetPlatformInfo, platform_id, 0x0902),
                    "vendor": get_string(loader.clGetPlatformInfo, platform_id, 0x0903),
                    "version": get_string(loader.clGetPlatformInfo, platform_id, 0x0901),
                    "profile": get_string(loader.clGetPlatformInfo, platform_id, 0x0900),
                    "devices": [],
                }
                device_count = cl_uint()
                device_code = loader.clGetDeviceIDs(
                    platform_id, 0xFFFFFFFF, 0, None, ctypes.byref(device_count)
                )
                platform_record["cl_get_device_ids_code"] = device_code
                if device_code == 0 and device_count.value:
                    device_array = (cl_device_id * device_count.value)()
                    loader.clGetDeviceIDs(
                        platform_id,
                        0xFFFFFFFF,
                        device_count,
                        device_array,
                        None,
                    )
                    for device_id in device_array:
                        global_memory = get_scalar(
                            loader.clGetDeviceInfo, device_id, 0x101F, cl_ulong
                        )
                        local_memory = get_scalar(
                            loader.clGetDeviceInfo, device_id, 0x1023, cl_ulong
                        )
                        platform_record["devices"].append(
                            {
                                "name": get_string(loader.clGetDeviceInfo, device_id, 0x102B),
                                "vendor": get_string(loader.clGetDeviceInfo, device_id, 0x102C),
                                "driver_version": get_string(loader.clGetDeviceInfo, device_id, 0x102D),
                                "device_version": get_string(loader.clGetDeviceInfo, device_id, 0x102F),
                                "opencl_c_version": get_string(loader.clGetDeviceInfo, device_id, 0x103D),
                                "type_bits": get_scalar(loader.clGetDeviceInfo, device_id, 0x1000, cl_ulong),
                                "compute_units": get_scalar(loader.clGetDeviceInfo, device_id, 0x1002, cl_uint),
                                "max_clock_mhz": get_scalar(loader.clGetDeviceInfo, device_id, 0x100C, cl_uint),
                                "max_work_group_size": get_scalar(loader.clGetDeviceInfo, device_id, 0x1004, cl_size_t),
                                "global_memory_bytes": global_memory,
                                "local_memory_bytes": local_memory,
                                "available": bool(get_scalar(loader.clGetDeviceInfo, device_id, 0x1027, cl_uint)),
                                "compiler_available": bool(get_scalar(loader.clGetDeviceInfo, device_id, 0x1028, cl_uint)),
                            }
                        )
                report["opencl"]["platforms"].append(platform_record)
        else:
            report["opencl"]["error"] = "second clGetPlatformIDs call failed"
    elif code == -1001:
        report["opencl"]["error"] = "CL_PLATFORM_NOT_FOUND_KHR"
    else:
        report["opencl"]["error"] = "clGetPlatformIDs failed"
else:
    report["opencl"]["error"] = "OpenCL loader could not be loaded"

cpu_count = os.cpu_count()
meminfo = read_text("/proc/meminfo") or ""
available_kib = None
for line in meminfo.splitlines():
    if line.startswith("MemAvailable:"):
        available_kib = int(line.split()[1])
        break

report["resources"] = {
    "logical_cpus": cpu_count,
    "cpu_model": command_output(["sh", "-c", "grep -m1 -E 'model name|Processor' /proc/cpuinfo | cut -d: -f2-"]),
    "memory_available_kib": available_kib,
    "npu_load": read_text("/sys/kernel/debug/rknpu/load"),
    "mali_device_present": os.path.exists("/dev/mali0"),
    "render_devices": sorted(glob.glob("/dev/dri/renderD*")),
}

device_count = sum(len(item["devices"]) for item in report["opencl"]["platforms"])
gpu_like = any(
    (device.get("type_bits") or 0) & 0x4
    for item in report["opencl"]["platforms"]
    for device in item["devices"]
)
if report["opencl"]["call_passed"] and gpu_like:
    report["assessment"] = "READY_FOR_OPENCL_INFERENCE_BACKEND_PROBE"
elif report["opencl"]["call_passed"] and device_count:
    report["assessment"] = "OPENCL_AVAILABLE_WITHOUT_GPU_DEVICE"
else:
    report["assessment"] = "BLOCKED_OPENCL_RUNTIME"

with open(sys.argv[1], "w", encoding="utf-8") as handle:
    json.dump(report, handle, indent=2, sort_keys=False)
    handle.write("\n")
PY

printf '%s\n' '---OPENCL_JSON_BEGIN---'
cat "$report_file"
printf '%s\n' '---OPENCL_JSON_END---'

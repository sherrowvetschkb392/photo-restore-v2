#!/bin/sh
# Isolated OpenCL compute smoke test for the installed Mali runtime.
# It writes only to a temporary report file and removes it before exit.
set -eu

export LC_ALL=C
report_file="$(mktemp /tmp/photo-restore-opencl-smoke.XXXXXX.json)"
trap 'rm -f "$report_file"' EXIT INT TERM

set +e
python3 - "$report_file" <<'PY'
import ctypes
import ctypes.util
import json
import math
import os
import platform
import sys
import time


CL_SUCCESS = 0
CL_DEVICE_TYPE_GPU = 1 << 2
CL_MEM_READ_WRITE = 1 << 0
CL_TRUE = 1
CL_PROGRAM_BUILD_LOG = 0x1183
CL_DEVICE_NAME = 0x102B
CL_DEVICE_VENDOR = 0x102C
CL_DRIVER_VERSION = 0x102D

ELEMENTS = 1 << 20
REPEATS = 20
LOCAL_SIZE = 256


class OpenCLError(RuntimeError):
    pass


def check(code, operation):
    if code != CL_SUCCESS:
        raise OpenCLError(f"{operation} failed with OpenCL code {code}")


def load_opencl():
    candidates = [ctypes.util.find_library("OpenCL"), "libOpenCL.so.1"]
    last_error = None
    for candidate in candidates:
        if not candidate:
            continue
        try:
            return ctypes.CDLL(candidate), candidate
        except OSError as exc:
            last_error = str(exc)
    raise OpenCLError(f"unable to load OpenCL: {last_error}")


report = {
    "schema_version": 1,
    "result": "FAIL",
    "board_changed": False,
    "platform": {
        "architecture": platform.machine(),
        "kernel": platform.release(),
        "python": platform.python_version(),
    },
    "workload": {
        "operation": "out[i] = a[i] * scale + b[i]",
        "elements": ELEMENTS,
        "repeats": REPEATS,
        "local_size": LOCAL_SIZE,
        "bytes_per_buffer": ELEMENTS * 4,
    },
    "device": {},
    "timing_seconds": {},
    "validation": {},
    "error": None,
}

objects = []
try:
    cl, loader_path = load_opencl()
    report["loader"] = loader_path

    cl_int = ctypes.c_int
    cl_uint = ctypes.c_uint
    cl_ulong = ctypes.c_ulong
    cl_size_t = ctypes.c_size_t
    cl_bool = cl_uint
    cl_platform_id = ctypes.c_void_p
    cl_device_id = ctypes.c_void_p
    cl_context = ctypes.c_void_p
    cl_command_queue = ctypes.c_void_p
    cl_program = ctypes.c_void_p
    cl_kernel = ctypes.c_void_p
    cl_mem = ctypes.c_void_p

    cl.clGetPlatformIDs.argtypes = [cl_uint, ctypes.POINTER(cl_platform_id), ctypes.POINTER(cl_uint)]
    cl.clGetPlatformIDs.restype = cl_int
    cl.clGetDeviceIDs.argtypes = [cl_platform_id, cl_ulong, cl_uint, ctypes.POINTER(cl_device_id), ctypes.POINTER(cl_uint)]
    cl.clGetDeviceIDs.restype = cl_int
    cl.clGetDeviceInfo.argtypes = [cl_device_id, cl_uint, cl_size_t, ctypes.c_void_p, ctypes.POINTER(cl_size_t)]
    cl.clGetDeviceInfo.restype = cl_int
    cl.clCreateContext.argtypes = [ctypes.c_void_p, cl_uint, ctypes.POINTER(cl_device_id), ctypes.c_void_p, ctypes.c_void_p, ctypes.POINTER(cl_int)]
    cl.clCreateContext.restype = cl_context
    cl.clCreateCommandQueue.argtypes = [cl_context, cl_device_id, cl_ulong, ctypes.POINTER(cl_int)]
    cl.clCreateCommandQueue.restype = cl_command_queue
    cl.clCreateProgramWithSource.argtypes = [cl_context, cl_uint, ctypes.POINTER(ctypes.c_char_p), ctypes.POINTER(cl_size_t), ctypes.POINTER(cl_int)]
    cl.clCreateProgramWithSource.restype = cl_program
    cl.clBuildProgram.argtypes = [cl_program, cl_uint, ctypes.POINTER(cl_device_id), ctypes.c_char_p, ctypes.c_void_p, ctypes.c_void_p]
    cl.clBuildProgram.restype = cl_int
    cl.clGetProgramBuildInfo.argtypes = [cl_program, cl_device_id, cl_uint, cl_size_t, ctypes.c_void_p, ctypes.POINTER(cl_size_t)]
    cl.clGetProgramBuildInfo.restype = cl_int
    cl.clCreateKernel.argtypes = [cl_program, ctypes.c_char_p, ctypes.POINTER(cl_int)]
    cl.clCreateKernel.restype = cl_kernel
    cl.clCreateBuffer.argtypes = [cl_context, cl_ulong, cl_size_t, ctypes.c_void_p, ctypes.POINTER(cl_int)]
    cl.clCreateBuffer.restype = cl_mem
    cl.clEnqueueWriteBuffer.argtypes = [cl_command_queue, cl_mem, cl_bool, cl_size_t, cl_size_t, ctypes.c_void_p, cl_uint, ctypes.c_void_p, ctypes.c_void_p]
    cl.clEnqueueWriteBuffer.restype = cl_int
    cl.clSetKernelArg.argtypes = [cl_kernel, cl_uint, cl_size_t, ctypes.c_void_p]
    cl.clSetKernelArg.restype = cl_int
    cl.clEnqueueNDRangeKernel.argtypes = [cl_command_queue, cl_kernel, cl_uint, ctypes.c_void_p, ctypes.POINTER(cl_size_t), ctypes.POINTER(cl_size_t), cl_uint, ctypes.c_void_p, ctypes.c_void_p]
    cl.clEnqueueNDRangeKernel.restype = cl_int
    cl.clFinish.argtypes = [cl_command_queue]
    cl.clFinish.restype = cl_int
    cl.clEnqueueReadBuffer.argtypes = [cl_command_queue, cl_mem, cl_bool, cl_size_t, cl_size_t, ctypes.c_void_p, cl_uint, ctypes.c_void_p, ctypes.c_void_p]
    cl.clEnqueueReadBuffer.restype = cl_int
    cl.clReleaseMemObject.argtypes = [cl_mem]
    cl.clReleaseKernel.argtypes = [cl_kernel]
    cl.clReleaseProgram.argtypes = [cl_program]
    cl.clReleaseCommandQueue.argtypes = [cl_command_queue]
    cl.clReleaseContext.argtypes = [cl_context]

    def device_string(device, parameter):
        size = cl_size_t()
        check(cl.clGetDeviceInfo(device, parameter, 0, None, ctypes.byref(size)), "clGetDeviceInfo(size)")
        buffer = ctypes.create_string_buffer(size.value)
        check(cl.clGetDeviceInfo(device, parameter, size.value, buffer, None), "clGetDeviceInfo(value)")
        return buffer.value.decode("utf-8", errors="replace")

    platform_count = cl_uint()
    check(cl.clGetPlatformIDs(0, None, ctypes.byref(platform_count)), "clGetPlatformIDs(count)")
    if platform_count.value < 1:
        raise OpenCLError("no OpenCL platform was returned")
    platforms = (cl_platform_id * platform_count.value)()
    check(cl.clGetPlatformIDs(platform_count, platforms, None), "clGetPlatformIDs(values)")

    selected_device = None
    for platform_id in platforms:
        device_count = cl_uint()
        code = cl.clGetDeviceIDs(platform_id, CL_DEVICE_TYPE_GPU, 0, None, ctypes.byref(device_count))
        if code == CL_SUCCESS and device_count.value:
            devices = (cl_device_id * device_count.value)()
            check(cl.clGetDeviceIDs(platform_id, CL_DEVICE_TYPE_GPU, device_count, devices, None), "clGetDeviceIDs(values)")
            selected_device = devices[0]
            break
    if selected_device is None:
        raise OpenCLError("no GPU OpenCL device was returned")

    report["device"] = {
        "name": device_string(selected_device, CL_DEVICE_NAME),
        "vendor": device_string(selected_device, CL_DEVICE_VENDOR),
        "driver_version": device_string(selected_device, CL_DRIVER_VERSION),
    }

    error = cl_int()
    device_array = (cl_device_id * 1)(selected_device)
    context = cl.clCreateContext(None, 1, device_array, None, None, ctypes.byref(error))
    check(error.value, "clCreateContext")
    objects.append((cl.clReleaseContext, context))
    queue = cl.clCreateCommandQueue(context, selected_device, 0, ctypes.byref(error))
    check(error.value, "clCreateCommandQueue")
    objects.append((cl.clReleaseCommandQueue, queue))

    source_text = r"""
    __kernel void saxpy(
        __global const float *a,
        __global const float *b,
        __global float *out,
        const float scale)
    {
        const size_t i = get_global_id(0);
        out[i] = a[i] * scale + b[i];
    }
    """.encode("utf-8")
    source = ctypes.c_char_p(source_text)
    source_length = cl_size_t(len(source_text))
    compile_start = time.perf_counter()
    program = cl.clCreateProgramWithSource(context, 1, ctypes.byref(source), ctypes.byref(source_length), ctypes.byref(error))
    check(error.value, "clCreateProgramWithSource")
    objects.append((cl.clReleaseProgram, program))
    build_code = cl.clBuildProgram(program, 1, device_array, None, None, None)
    if build_code != CL_SUCCESS:
        log_size = cl_size_t()
        cl.clGetProgramBuildInfo(program, selected_device, CL_PROGRAM_BUILD_LOG, 0, None, ctypes.byref(log_size))
        log = ctypes.create_string_buffer(max(log_size.value, 1))
        cl.clGetProgramBuildInfo(program, selected_device, CL_PROGRAM_BUILD_LOG, log_size.value, log, None)
        raise OpenCLError(f"clBuildProgram failed with code {build_code}: {log.value.decode(errors='replace')}")
    report["timing_seconds"]["compile"] = round(time.perf_counter() - compile_start, 6)

    kernel = cl.clCreateKernel(program, b"saxpy", ctypes.byref(error))
    check(error.value, "clCreateKernel")
    objects.append((cl.clReleaseKernel, kernel))

    float_array = ctypes.c_float * ELEMENTS
    host_a = float_array()
    host_b = float_array()
    host_out = float_array()
    for i in range(ELEMENTS):
        host_a[i] = ((i % 1024) - 512) / 128.0
        host_b[i] = ((i * 7) % 2048) / 256.0
    scale = ctypes.c_float(1.75)
    buffer_bytes = ctypes.sizeof(host_a)

    buffers = []
    for name in ("a", "b", "out"):
        value = cl.clCreateBuffer(context, CL_MEM_READ_WRITE, buffer_bytes, None, ctypes.byref(error))
        check(error.value, f"clCreateBuffer({name})")
        buffers.append(value)
        objects.append((cl.clReleaseMemObject, value))
    buffer_a, buffer_b, buffer_out = buffers

    transfer_start = time.perf_counter()
    check(cl.clEnqueueWriteBuffer(queue, buffer_a, CL_TRUE, 0, buffer_bytes, host_a, 0, None, None), "clEnqueueWriteBuffer(a)")
    check(cl.clEnqueueWriteBuffer(queue, buffer_b, CL_TRUE, 0, buffer_bytes, host_b, 0, None, None), "clEnqueueWriteBuffer(b)")
    report["timing_seconds"]["host_to_device"] = round(time.perf_counter() - transfer_start, 6)

    check(cl.clSetKernelArg(kernel, 0, ctypes.sizeof(buffer_a), ctypes.byref(buffer_a)), "clSetKernelArg(a)")
    check(cl.clSetKernelArg(kernel, 1, ctypes.sizeof(buffer_b), ctypes.byref(buffer_b)), "clSetKernelArg(b)")
    check(cl.clSetKernelArg(kernel, 2, ctypes.sizeof(buffer_out), ctypes.byref(buffer_out)), "clSetKernelArg(out)")
    check(cl.clSetKernelArg(kernel, 3, ctypes.sizeof(scale), ctypes.byref(scale)), "clSetKernelArg(scale)")

    global_size = cl_size_t(ELEMENTS)
    local_size = cl_size_t(LOCAL_SIZE)
    compute_start = time.perf_counter()
    for _ in range(REPEATS):
        check(cl.clEnqueueNDRangeKernel(queue, kernel, 1, None, ctypes.byref(global_size), ctypes.byref(local_size), 0, None, None), "clEnqueueNDRangeKernel")
    check(cl.clFinish(queue), "clFinish")
    compute_seconds = time.perf_counter() - compute_start
    report["timing_seconds"]["compute_total"] = round(compute_seconds, 6)
    report["timing_seconds"]["compute_per_repeat"] = round(compute_seconds / REPEATS, 6)

    read_start = time.perf_counter()
    check(cl.clEnqueueReadBuffer(queue, buffer_out, CL_TRUE, 0, buffer_bytes, host_out, 0, None, None), "clEnqueueReadBuffer")
    report["timing_seconds"]["device_to_host"] = round(time.perf_counter() - read_start, 6)

    maximum_error = 0.0
    mismatch_count = 0
    for i in range(ELEMENTS):
        expected = float(host_a[i]) * float(scale.value) + float(host_b[i])
        error_value = abs(float(host_out[i]) - expected)
        maximum_error = max(maximum_error, error_value)
        if error_value > 1e-5:
            mismatch_count += 1
    report["validation"] = {
        "passed": mismatch_count == 0,
        "mismatch_count": mismatch_count,
        "maximum_absolute_error": maximum_error,
        "sample_output": [float(host_out[i]) for i in (0, 1, 2, ELEMENTS - 1)],
    }
    if mismatch_count:
        raise OpenCLError(f"validation failed with {mismatch_count} mismatches")
    report["result"] = "PASS"
except Exception as exc:
    report["error"] = f"{type(exc).__name__}: {exc}"
finally:
    for release, handle in reversed(objects):
        if handle:
            release(handle)
    with open(sys.argv[1], "w", encoding="utf-8") as handle:
        json.dump(report, handle, indent=2)
        handle.write("\n")

if report["result"] != "PASS":
    sys.exit(1)
PY
code=$?
set -e

printf '%s\n' '---OPENCL_SMOKE_JSON_BEGIN---'
cat "$report_file"
printf '%s\n' '---OPENCL_SMOKE_JSON_END---'
exit "$code"

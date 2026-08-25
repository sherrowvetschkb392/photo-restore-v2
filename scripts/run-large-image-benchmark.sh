#!/bin/sh
# Run one isolated large-image benchmark independently from the SSH connection.

set -u

if [ "$#" -ne 11 ]; then
    echo "usage: $0 PYTHON WORKER INPUT OUTPUT PREVIEW MODEL REPORT MAX_PIXELS WORKDIR STATUS PID" >&2
    exit 64
fi

python_bin=$1
worker=$2
input=$3
output=$4
preview=$5
model=$6
report=$7
max_pixels=$8
work_dir=$9
status_file=${10}
pid_file=${11}
status_tmp="${status_file}.tmp"
child_pid=""

finish_status() {
    final_status=$1
    printf '%s\n' "$final_status" > "$status_tmp"
    mv -f "$status_tmp" "$status_file"
    rm -f "$pid_file"
}

terminate_job() {
    if [ -n "$child_pid" ]; then
        kill "$child_pid" 2>/dev/null || true
        wait "$child_pid" 2>/dev/null || true
    fi
    finish_status "FAILED:143"
    exit 143
}

trap terminate_job HUP INT TERM

printf '%s\n' "$$" > "$pid_file"
printf '%s\n' "RUNNING" > "$status_tmp"
mv -f "$status_tmp" "$status_file"
printf 'RUNNER_STARTED pid=%s utc=%s\n' "$$" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"

"$python_bin" "$worker" \
    --input "$input" \
    --output "$output" \
    --preview-output "$preview" \
    --preview-max-edge 1600 \
    --model "$model" \
    --report "$report" \
    --max-input-pixels "$max_pixels" \
    --compositor disk \
    --work-dir "$work_dir" &
child_pid=$!
wait "$child_pid"
exit_code=$?
child_pid=""
printf 'WORKER_EXIT code=%s utc=%s\n' "$exit_code" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"

if [ "$exit_code" -eq 0 ] && [ -s "$output" ] && [ -s "$preview" ] && [ -s "$report" ]; then
    final_status="COMPLETE"
else
    final_status="FAILED:${exit_code}"
fi
finish_status "$final_status"
exit "$exit_code"

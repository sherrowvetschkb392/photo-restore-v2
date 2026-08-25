#!/bin/sh
# Run one image restoration independently from the SSH connection.

set -u

if [ "$#" -ne 9 ]; then
    echo "usage: $0 PYTHON WORKER INPUT OUTPUT MODEL REPORT MAX_PIXELS STATUS PID" >&2
    exit 64
fi

python_bin=$1
worker=$2
input=$3
output=$4
model=$5
report=$6
max_pixels=$7
status_file=$8
pid_file=$9
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

"$python_bin" "$worker" \
    --input "$input" \
    --output "$output" \
    --model "$model" \
    --report "$report" \
    --max-input-pixels "$max_pixels" &
child_pid=$!
wait "$child_pid"
exit_code=$?
child_pid=""

if [ "$exit_code" -eq 0 ] && [ -s "$output" ] && [ -s "$report" ]; then
    final_status="COMPLETE"
else
    final_status="FAILED:${exit_code}"
fi
finish_status "$final_status"
exit "$exit_code"

#!/bin/sh
set -u

pid_file=$1
shift
echo "$$" > "$pid_file"
child=0
cleanup() { rm -f "$pid_file"; }
forward_term() { [ "$child" -gt 0 ] && kill -TERM "$child" 2>/dev/null || true; }
trap cleanup EXIT
trap forward_term INT TERM HUP

"$@" &
child=$!
wait "$child"
status=$?
child=0
exit "$status"

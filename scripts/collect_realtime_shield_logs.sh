#!/bin/zsh

set -euo pipefail

duration="${1:-30m}"
device_udid="${2:-}"
output_root="${3:-logs/realtime-shield}"

if [[ ! "$duration" =~ ^[1-9][0-9]*[mhd]$ ]]; then
    print -u2 "usage: $0 [duration: 30m|2h|1d] [device-udid] [output-root]"
    exit 2
fi

timestamp="$(/bin/date -u +%Y%m%dT%H%M%SZ)"
output_dir="${output_root}/${timestamp}"
archive="${output_dir}/realtime-shield.logarchive"
predicate='subsystem == "com.slowth.realtimeshield"'
error_predicate="${predicate} AND (logType == \"error\" OR logType == \"fault\")"
metrics_predicate="${predicate} AND composedMessage BEGINSWITH \"metrics \""

/bin/mkdir -p "$output_dir"

device_options=(--device)
if [[ -n "$device_udid" ]]; then
    device_options=(--device-udid "$device_udid")
fi

print "Collecting ${duration} from the connected iPhone..."
collect_arguments=(collect "${device_options[@]}" --last "$duration" \
    --predicate "$predicate" --output "$archive")
if (( EUID == 0 )); then
    /usr/bin/log "${collect_arguments[@]}"
else
    print "macOS requires an administrator password to read logs from a physical device."
    /usr/bin/sudo /usr/bin/log "${collect_arguments[@]}"
fi

/usr/bin/log show "$archive" --style ndjson --predicate "$predicate" \
    > "${output_dir}/events.ndjson"
/usr/bin/log show "$archive" --style ndjson --predicate "$error_predicate" \
    > "${output_dir}/errors.ndjson"
/usr/bin/log show "$archive" --style compact --predicate "$error_predicate" \
    > "${output_dir}/errors.log"
/usr/bin/log show "$archive" --style ndjson --predicate "$metrics_predicate" \
    > "${output_dir}/metrics.ndjson"
/usr/bin/log show "$archive" --style compact --predicate "$metrics_predicate" \
    > "${output_dir}/metrics.log"

event_count="$(/usr/bin/wc -l < "${output_dir}/events.ndjson" | /usr/bin/tr -d ' ')"
error_count="$(/usr/bin/wc -l < "${output_dir}/errors.ndjson" | /usr/bin/tr -d ' ')"
metrics_count="$(/usr/bin/wc -l < "${output_dir}/metrics.ndjson" | /usr/bin/tr -d ' ')"
detection_count="$(/usr/bin/grep -c 'detected' "${output_dir}/events.ndjson" || true)"

{
    print "Realtime Shield device log summary"
    print "collected_at_utc=${timestamp}"
    print "lookback=${duration}"
    print "events=${event_count}"
    print "errors=${error_count}"
    print "metric_snapshots=${metrics_count}"
    print "detections=${detection_count}"
    print "archive=${archive}"
} > "${output_dir}/summary.txt"

print "Saved device logs to ${output_dir}"
print "Open ${archive} in Console.app for the full timeline."

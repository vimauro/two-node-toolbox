#!/usr/bin/bash

set -euo pipefail

# Script to trim log files from a specific time onwards
# Usage: ./trim-logs-by-time.sh HH:MM:SS [logs_directory]

if [[ $# -lt 1 ]]; then
    echo "Usage: $0 HH:MM:SS [logs_directory]"
    echo "Example: $0 14:30:00"
    echo "Example: $0 14:30:00 logs/20251016-153751"
    exit 1
fi

TIME_FILTER="$1"
LOGS_DIR="${2:-.}"

# Validate time format (HH:MM:SS)
if ! [[ "$TIME_FILTER" =~ ^[0-9]{2}:[0-9]{2}:[0-9]{2}$ ]]; then
    echo "Error: Time must be in HH:MM:SS format (e.g., 14:30:00)"
    exit 1
fi

# Check if logs directory exists
if [[ ! -d "$LOGS_DIR" ]]; then
    echo "Error: Directory '$LOGS_DIR' does not exist"
    exit 1
fi

echo "Trimming logs from time: $TIME_FILTER onwards"
echo "Logs directory: $LOGS_DIR"
echo ""

# Counter for processed files
PROCESSED=0

# Process all log files in the directory
for logfile in "$LOGS_DIR"/*.log; do
    # Skip if no log files found
    [[ -e "$logfile" ]] || continue

    filename=$(basename "$logfile")
    trimmed_file="${logfile%.log}-trimmed.log"

    # Determine log type and use appropriate awk pattern
    if [[ "$filename" == *"pacemaker"* ]]; then
        # Pacemaker logs format: "Oct 15 12:49:00"
        # Extract time portion and compare
        awk -v time="$TIME_FILTER" '
            BEGIN { found = 0 }
            {
                # Extract time from pacemaker log line (format: "Oct 15 HH:MM:SS")
                if (match($0, /[0-9]{2}:[0-9]{2}:[0-9]{2}/)) {
                    log_time = substr($0, RSTART, RLENGTH)
                    if (log_time >= time) {
                        found = 1
                    }
                }
                if (found) print
            }
        ' "$logfile" > "$trimmed_file"
    elif [[ "$filename" == *"etcd"* ]]; then
        # Etcd logs format: "2025-10-15T15:13:00.376993Z"
        # Extract time portion and compare
        awk -v time="$TIME_FILTER" '
            BEGIN { found = 0 }
            {
                # Extract time from ISO timestamp (format: "YYYY-MM-DDTHH:MM:SS")
                if (match($0, /T[0-9]{2}:[0-9]{2}:[0-9]{2}/)) {
                    log_time = substr($0, RSTART+1, 8)  # Skip the 'T'
                    if (log_time >= time) {
                        found = 1
                    }
                }
                if (found) print
            }
        ' "$logfile" > "$trimmed_file"
    else
        # Generic fallback: look for HH:MM:SS pattern
        awk -v time="$TIME_FILTER" '
            BEGIN { found = 0 }
            {
                if (match($0, /[0-9]{2}:[0-9]{2}:[0-9]{2}/)) {
                    log_time = substr($0, RSTART, RLENGTH)
                    if (log_time >= time) {
                        found = 1
                    }
                }
                if (found) print
            }
        ' "$logfile" > "$trimmed_file"
    fi

    # Check if trimmed file has content
    if [[ -s "$trimmed_file" ]]; then
        original_lines=$(wc -l < "$logfile")
        trimmed_lines=$(wc -l < "$trimmed_file")
        echo "✓ $filename: $original_lines lines → $trimmed_lines lines (trimmed)"
        PROCESSED=$((PROCESSED + 1))
    else
        echo "✗ $filename: No lines found from $TIME_FILTER onwards (file removed)"
        rm "$trimmed_file"
    fi
done

echo ""
echo "Processed $PROCESSED log files"
echo "Trimmed files saved with '-trimmed.log' suffix"

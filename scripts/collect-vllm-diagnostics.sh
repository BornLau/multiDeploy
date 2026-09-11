#!/usr/bin/env bash
set -Eeuo pipefail

DASHBOARD_URL=${DASHBOARD_URL:-http://127.0.0.1:3000}
OUTPUT_PARENT=${OUTPUT_PARENT:-./diagnostics}
STAMP=$(date '+%Y%m%d-%H%M%S')
OUTPUT_FILE="$OUTPUT_PARENT/vllm-$STAMP.txt"

mkdir -p "$OUTPUT_PARENT"
curl --fail --silent --show-error --max-time 30 \
  "$DASHBOARD_URL/api/report" > "$OUTPUT_FILE"

SIZE=$(wc -c < "$OUTPUT_FILE" | tr -d ' ')
if (( SIZE > 10000 )); then
  printf 'diagnostic report unexpectedly exceeds 10KB: %s bytes\n' "$SIZE" >&2
  exit 1
fi

printf 'Diagnostic text created (%s bytes):\n%s\n' "$SIZE" "$OUTPUT_FILE"

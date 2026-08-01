#!/bin/bash

set -euo pipefail

readonly REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly TEST_DIR="$(mktemp -d)"
readonly RADAR_CURL_COUNT_FILE="$TEST_DIR/curl-count"
export RADAR_CURL_COUNT_FILE
export OMARCHY_RADAR_CREDS="$TEST_DIR/no-credentials"
export XDG_RUNTIME_DIR="$TEST_DIR"

cleanup() {
  rm -f "$RADAR_CURL_COUNT_FILE"
  rmdir "$TEST_DIR"
}
trap cleanup EXIT

curl() {
  local count=0
  [[ -r $RADAR_CURL_COUNT_FILE ]] && read -r count <"$RADAR_CURL_COUNT_FILE"
  count=$((count + 1))
  printf '%s\n' "$count" >"$RADAR_CURL_COUNT_FILE"

  printf '{"time":%d,"states":[["plane-%d"]]}\n200\n%d\n\n.' \
    "$count" "$count" "$((400 - count))"
}
export -f curl

result=$(bash "$REPO_DIR/opensky-fetch" \
  -2 177 2 180 \
  -2 -180 2 -179)

jq -e '
  .time == 2
  and .remaining == 398
  and (.states | map(.[0])) == ["plane-1", "plane-2"]
' <<<"$result" >/dev/null

[[ $(<"$RADAR_CURL_COUNT_FILE") == 2 ]]

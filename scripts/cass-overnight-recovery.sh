#!/bin/zsh

# Durable overnight archive recovery runner. It resumes the lexical checkpoint,
# retries transient exits, then runs semantic indexing and the final doctor scan.

set -u

DATA_DIR="${1:?usage: cass-overnight-recovery.sh DATA_DIR LOG_DIR}"
LOG_DIR="${2:?usage: cass-overnight-recovery.sh DATA_DIR LOG_DIR}"
ROOT_DIR="${0:A:h:h}"
BINARY="$ROOT_DIR/target/release/cass"
STATE_FILE="$DATA_DIR/index/v8/.lexical-rebuild-state.json"

mkdir -p "$LOG_DIR"
date -u +%s > "$LOG_DIR/runner-started"

run_lexical_until_complete() {
  local attempt=0
  while true; do
    if [[ -f "$STATE_FILE" ]] && jq -e '.completed == true' "$STATE_FILE" >/dev/null 2>&1; then
      return 0
    fi

    attempt=$((attempt + 1))
    local lexical_status=0
    CASS_TANTIVY_REBUILD_PAGE_PREP_WORKERS=1 \
    CASS_TANTIVY_REBUILD_WORKERS=1 \
    CASS_TANTIVY_REBUILD_BATCH_FETCH_CONVERSATIONS=1 \
    CASS_TANTIVY_REBUILD_INITIAL_BATCH_FETCH_CONVERSATIONS=1 \
    CASS_TANTIVY_REBUILD_INITIAL_COMMIT_EVERY_CONVERSATIONS=1 \
    CASS_TANTIVY_REBUILD_INITIAL_COMMIT_EVERY_MESSAGES=1000 \
    CASS_TANTIVY_REBUILD_INITIAL_COMMIT_EVERY_MESSAGE_BYTES=16777216 \
    CASS_TANTIVY_REBUILD_PIPELINE_MAX_MESSAGE_BYTES_IN_FLIGHT=67108864 \
    CASS_INDEX_STALL_ABORT_SECS=1800 \
      "$BINARY" index --json --no-progress-events --data-dir "$DATA_DIR" \
      >"$LOG_DIR/lexical-$attempt.json" 2>"$LOG_DIR/lexical-$attempt.log" || lexical_status=$?

    if [[ -f "$STATE_FILE" ]] && jq -e '.completed == true' "$STATE_FILE" >/dev/null 2>&1; then
      return 0
    fi

    printf '%s %s\n' "$attempt" "$lexical_status" >> "$LOG_DIR/lexical-retries"
    sleep 30
  done
}

if ! run_lexical_until_complete; then
  date -u +%s > "$LOG_DIR/lexical-blocked"
  exit 70
fi

semantic_status=0
CASS_INDEX_STALL_ABORT_SECS=1800 \
  "$BINARY" index --semantic --build-hnsw --json --no-progress-events \
  --data-dir "$DATA_DIR" >"$LOG_DIR/semantic.json" 2>"$LOG_DIR/semantic.log" || semantic_status=$?
echo "$semantic_status" > "$LOG_DIR/semantic.exit"

doctor_status=0
CASS_DOCTOR_DB_PROBE_TIMEOUT_SECS=600 \
CASS_DOCTOR_RAW_MIRROR_FULL_VERIFY=1 \
  "$BINARY" doctor --check --json --verbose \
  --data-dir "$DATA_DIR" >"$LOG_DIR/doctor.json" 2>"$LOG_DIR/doctor.log" || doctor_status=$?
echo "$doctor_status" > "$LOG_DIR/doctor.exit"

if [[ "$semantic_status" -eq 0 && "$doctor_status" -eq 0 ]]; then
  date -u +%s > "$LOG_DIR/runner-complete"
  exit 0
fi

date -u +%s > "$LOG_DIR/runner-warning"
exit 70

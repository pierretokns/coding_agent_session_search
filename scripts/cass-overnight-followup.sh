#!/bin/zsh

# Persistent post-lexical recovery runner for a launchd-owned CASS rebuild.
# It waits for the lexical checkpoint, then runs semantic indexing and the
# extended read-only doctor scan without touching the canonical archive.

set -u

DATA_DIR="${1:?usage: cass-overnight-followup.sh DATA_DIR LEXICAL_LABEL LOG_DIR}"
LEXICAL_LABEL="${2:?usage: cass-overnight-followup.sh DATA_DIR LEXICAL_LABEL LOG_DIR}"
LOG_DIR="${3:?usage: cass-overnight-followup.sh DATA_DIR LEXICAL_LABEL LOG_DIR}"
ROOT_DIR="${0:A:h:h}"
BINARY="$ROOT_DIR/target/release/cass"
STATE_FILE="$DATA_DIR/index/v8/.lexical-rebuild-state.json"
RUN_MARKER="$LOG_DIR/followup-started"

mkdir -p "$LOG_DIR"
date -u +%s > "$RUN_MARKER"

wait_for_lexical() {
  while true; do
    if [[ -f "$STATE_FILE" ]] && jq -e '.completed == true' "$STATE_FILE" >/dev/null 2>&1; then
      return 0
    fi

    local launch_state
    launch_state="$(launchctl print "gui/$(id -u)/$LEXICAL_LABEL" 2>/dev/null | sed -n 's/^[[:space:]]*state = //p' | head -1)"
    if [[ "$launch_state" != "running" && "$launch_state" != "active" ]]; then
      echo "lexical job stopped before completed checkpoint: state=${launch_state:-missing}" >&2
      return 70
    fi
    sleep 60
  done
}

if ! wait_for_lexical; then
  date -u +%s > "$LOG_DIR/followup-blocked"
  exit 70
fi

semantic_log="$LOG_DIR/semantic.json"
semantic_err="$LOG_DIR/semantic.log"
semantic_status=0

CASS_INDEX_STALL_ABORT_SECS=1800 \
  "$BINARY" index --semantic --build-hnsw --json --no-progress-events \
  --data-dir "$DATA_DIR" >"$semantic_log" 2>"$semantic_err" || semantic_status=$?
echo "$semantic_status" > "$LOG_DIR/semantic.exit"

doctor_log="$LOG_DIR/doctor.json"
doctor_err="$LOG_DIR/doctor.log"
doctor_status=0

CASS_DOCTOR_DB_PROBE_TIMEOUT_SECS=600 \
CASS_DOCTOR_RAW_MIRROR_FULL_VERIFY=1 \
  "$BINARY" doctor --check --json --verbose \
  --data-dir "$DATA_DIR" >"$doctor_log" 2>"$doctor_err" || doctor_status=$?
echo "$doctor_status" > "$LOG_DIR/doctor.exit"

if [[ "$semantic_status" -eq 0 && "$doctor_status" -eq 0 ]]; then
  date -u +%s > "$LOG_DIR/followup-complete"
  exit 0
fi

date -u +%s > "$LOG_DIR/followup-warning"
exit 70

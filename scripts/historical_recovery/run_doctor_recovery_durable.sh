#!/bin/zsh
# Launch one archive recovery through launchd so it is independent of the
# invoking terminal. The Rust candidate ledger makes a later invocation
# resumable; this wrapper makes the invocation itself durable and observable.
set -euo pipefail

if [[ "$(uname -s)" != "Darwin" ]]; then
  print -u2 "run_doctor_recovery_durable.sh requires macOS launchd"
  exit 2
fi

uid="$(id -u)"
launch_domain="gui/${uid}"
cass_binary="${CASS_BINARY:-$(command -v cass || true)}"
if [[ -z "${cass_binary}" || ! -x "${cass_binary}" ]]; then
  print -u2 "cass binary not found; set CASS_BINARY to an absolute executable path"
  exit 2
fi

data_dir="${CASS_DATA_DIR:-${HOME}/Library/Application Support/com.coding-agent-search.coding-agent-search}"
run_root="${data_dir}/doctor/runs"
run_id="doctor-recovery-$(date +%Y%m%d-%H%M%S)-$$"
run_dir="${run_root}/${run_id}"
label="com.pierretokns.cass.${run_id}"
plist_path="${run_dir}/${label}.plist"
stdout_path="${run_dir}/stdout.json"
stderr_path="${run_dir}/stderr.log"

mkdir -p "${run_dir}"

python3 - "${plist_path}" "${label}" "${cass_binary}" "${stdout_path}" "${stderr_path}" <<'PY'
import plistlib
import sys

path, label, binary, stdout_path, stderr_path = sys.argv[1:]
payload = {
    "Label": label,
    "ProgramArguments": [binary, "doctor", "--fix", "--json"],
    "EnvironmentVariables": {
        # This is a count of page buffers, not a byte budget.  32768 made
        # every recovery open reserve a large cache before any useful work;
        # keep the recovery cache bounded and let the OS cache the archive.
        "FSQLITE_PAGE_BUFFER_MAX": "8192",
        # The source ledger is a narrow read-only metadata query.  Use the
        # mature SQLite reader for it; FrankenSQLite remains the authority for
        # archive writes and candidate reconstruction.
        "CASS_DOCTOR_FAST_SOURCE_INVENTORY": "1",
        "CASS_DOCTOR_SKIP_DEEP_DB_PROBE": "1",
        # The live DB checksum is a 25GB full read used for promotion drift
        # detection. Recovery staging only needs size/sidecar/index metadata;
        # explicit promotion rechecks the live bundle before swapping it.
        "CASS_DOCTOR_DEFER_LIVE_INVENTORY_HASH": "1",
        # The verified raw mirror is the recovery source of truth. Avoid a
        # full FrankenSQLite COUNT probe of the 25GB live archive on a fresh
        # candidate; normal doctor checks retain that probe by default.
        "CASS_DOCTOR_SKIP_LIVE_ARCHIVE_COPY_PROBE": "1",
        "CASS_SKIP_PREFLIGHT_COUNT_TOTAL_MESSAGES": "1",
        # Recovery promotes the canonical archive first; lexical and
        # analytics assets are rebuilt as explicit post-promotion steps.
        # Deferring them here avoids doing O(n) derived maintenance for every
        # reconstructed conversation and keeps the candidate resumable.
        "CASS_DEFER_LEXICAL_UPDATES": "1",
        "CASS_DEFER_ANALYTICS_UPDATES": "1",
        # Raw mirror blobs are content-addressed and already captured with a
        # content hash. Reconstruction re-hashes each blob while streaming it;
        # avoid hashing the entire mirror a second time during preflight.
        "CASS_DOCTOR_TRUST_VERIFIED_RAW_MIRROR": "1",
    },
    "RunAtLoad": True,
    "KeepAlive": False,
    "ProcessType": "Background",
    "LowPriorityIO": True,
    "StandardOutPath": stdout_path,
    "StandardErrorPath": stderr_path,
}
with open(path, "wb") as handle:
    plistlib.dump(payload, handle, sort_keys=False)
PY

launchctl bootstrap "${launch_domain}" "${plist_path}"
print "${run_id}"
print "label=${label}"
print "run_dir=${run_dir}"
print "stdout=${stdout_path}"
print "stderr=${stderr_path}"
print "status=launchctl print ${launch_domain}/${label}"

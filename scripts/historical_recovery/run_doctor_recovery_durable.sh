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
        "FSQLITE_PAGE_BUFFER_MAX": "32768",
        "CASS_SKIP_PREFLIGHT_COUNT_TOTAL_MESSAGES": "1",
        # Recovery promotes the canonical archive first; lexical and
        # analytics assets are rebuilt as explicit post-promotion steps.
        # Deferring them here avoids doing O(n) derived maintenance for every
        # reconstructed conversation and keeps the candidate resumable.
        "CASS_DEFER_LEXICAL_UPDATES": "1",
        "CASS_DEFER_ANALYTICS_UPDATES": "1",
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

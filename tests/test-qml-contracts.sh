#!/bin/bash
# Static regressions for Service control-flow contracts. Quickshell's typed
# IpcHandler prevents standalone Panel.qml linting, so these pin the two
# failure paths that must not be changed into silent UI actions.
set -u
here="$(cd "$(dirname "$0")" && pwd)"
service="$here/../Service.qml"
pass=0 fail=0

expect() {
  local name="$1" condition="$2"
  if eval "$condition"; then echo "PASS $name"; pass=$((pass + 1))
  else echo "FAIL $name"; fail=$((fail + 1)); fi
}

unknown_block="$(awk '/if \(importStateUnknown\)/,/} else if \(op === "import"/' "$service")"
expect "exit 6 clears retry state and returns UI control without auto-retry" \
  'printf "%s\n" "$unknown_block" | grep -q "_editRetryUuid = \"\"" \
    && printf "%s\n" "$unknown_block" | grep -q "root.editFailed(reason)" \
    && ! printf "%s\n" "$unknown_block" | grep -q "retryEdit"'

saved_block="$(awk '/if \(exitCode === 0 \|\| savedNotUp\)/,/} else {/' "$service")"
expect "exit 5 clears editor retry state without auto-retry" \
  'printf "%s\n" "$saved_block" | grep -q "_editRetryUuid = \"\"" \
    && ! printf "%s\n" "$saved_block" | grep -q "retryEdit"'

rename_block="$(awk '/if \(value === profile.name\)/,/return true/' "$service")"
expect "idempotent rename clears stale action errors" \
  'printf "%s\n" "$rename_block" | grep -q "actionRejection = \"\"" \
    && printf "%s\n" "$rename_block" | grep -q "lastError = \"\"" \
    && printf "%s\n" "$rename_block" | grep -q "actionStatus = \"\""'

refresh_block="$(awk '/function refresh\(\)/,/^  }/' "$service")"
change_refresh_block="$(awk '/function refreshAfterChange\(\)/,/^  }/' "$service")"
status_block="$(awk '/id: statusProcess/,/^  }/' "$service")"
expect "only post-control refresh schedules one follow-up poll" \
  'grep -q "property bool _refreshAfterStatus: false" "$service" \
    && ! printf "%s\n" "$refresh_block" | grep -q "_refreshAfterStatus = true" \
    && printf "%s\n" "$change_refresh_block" | grep -q "_refreshAfterStatus = true" \
    && printf "%s\n" "$status_block" | grep -q "_refreshAfterStatus = false" \
    && printf "%s\n" "$status_block" | grep -q "Qt.callLater(root.refreshAfterChange)"'

commit_block="$(awk '/commit_import\(\)/,/^  }/' "$here/../backend.sh")"
expect "import commit keeps a terminal signal handler instead of a trap gap" \
  'printf "%s\n" "$commit_block" | grep -q "import_committed=1" \
    && printf "%s\n" "$commit_block" | grep -q "trap - EXIT" \
    && ! printf "%s\n" "$commit_block" | grep -q "trap - EXIT HUP INT TERM"'

echo "----"
echo "$pass passed, $fail failed"
[ "$fail" = 0 ]

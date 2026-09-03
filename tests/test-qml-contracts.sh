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
  'printf "%s\n" "$unknown_block" | grep -q "_editRetryIfname = \"\"" \
    && printf "%s\n" "$unknown_block" | grep -q "root.editFailed(reason)" \
    && ! printf "%s\n" "$unknown_block" | grep -q "retryEdit"'

saved_block="$(awk '/if \(exitCode === 0 \|\| savedNotUp\)/,/} else {/' "$service")"
expect "exit 5 clears editor retry state without auto-retry" \
  'printf "%s\n" "$saved_block" | grep -q "_editRetryIfname = \"\"" \
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

# The root helper re-validates every config body: awg-quick evaluates
# PostUp/PreUp/... as root, so a compromised user process must not be able
# to plant one even though backend.sh never emits hooks.
helper="$here/../helper/omarchy-amneziawg-helper"
sbin="$(mktemp -d)"; ln -s "$helper" "$sbin/omarchy-amneziawg-helper-secrets"
expect "helper writeconf rejects wg-quick hooks in the config body" \
  'grep -Eqi "PreUp|PostUp|PreDown|PostDown|SaveConfig" "$helper" \
    && printf "%s\n" '"'"'[Interface]
PrivateKey = k
PostUp = /bin/evil'"'"' | AWG_CONFDIR="$(mktemp -d)" bash "$sbin/omarchy-amneziawg-helper-secrets" writeconf hooky >/dev/null 2>&1; [ $? -ne 0 ]'

# backend.sh emits only canonical, hook-free config text — the parser must
# reject a hook rather than pass it through to the helper.
expect "backend parse_config rejects hooks before the helper is ever called" \
  'grep -q "awg-quick would run it as root" "$here/../backend.sh"'

# Secrets are gated: the passwordless helper entry point must refuse the
# key-bearing / destructive verbs, and the polkit policy must carry a
# distinct authenticating action for them.
expect "plain helper entry point refuses getconf/writeconf/delconf" \
  '! echo x | bash "$helper" getconf tun0 >/dev/null 2>&1 \
    && ! echo x | bash "$helper" writeconf tun0 >/dev/null 2>&1 \
    && ! bash "$helper" delconf tun0 >/dev/null 2>&1'
policy="$here/../polkit/com.omarchy.amneziawg.policy"
expect "polkit ships a separate authenticating action for the secrets entry point" \
  'grep -q "com.omarchy.amneziawg.helper.secrets" "$policy" \
    && grep -q "omarchy-amneziawg-helper-secrets" "$policy" \
    && grep -q "auth_admin_keep" "$policy"'

# Every Process that collects output with waitForEnd runs under a watchdog:
# a producer that never closes its pipe must not wedge the collector or the
# UI state cleared from onExited.
expect "each collecting Process arms and clears the watchdog" \
  '[ "$(grep -c "root._guard(" "$service")" -ge 11 ] \
    && [ "$(grep -c "root._unguard(" "$service")" -ge 11 ] \
    && grep -q "id: watchdogTimer" "$service"'

# A wedged process gets SIGTERM (so its EXIT trap can remove a temp file
# holding a private key) and only then SIGKILL, and the timeout is reported:
# the operation may still be running as root behind pkexec.
watchdog_block="$(awk '/id: watchdogTimer/,/^  }/' "$service")"
expect "the watchdog escalates TERM to KILL and surfaces the timeout" \
  'printf "%s\n" "$watchdog_block" | grep -q "signal(15)" \
    && printf "%s\n" "$watchdog_block" | grep -q "signal(9)" \
    && printf "%s\n" "$watchdog_block" | grep -q "root.lastError"'

# The last-tunnel marker is attacker-writable state under $HOME. FileView
# would follow a symlink and read the target whole; the shell read refuses a
# link, refuses a non-regular file, and is bounded.
lastfile_block="$(awk '/readonly property string lastFileScript/,/^$/' "$service")"
expect "the last-tunnel marker is read no-follow and bounded, not through FileView" \
  '! grep -qE "^[[:space:]]*FileView[[:space:]]*\{" "$service" \
    && printf "%s\n" "$lastfile_block" | grep -qE "\[ -L .+ \] && exit 1" \
    && printf "%s\n" "$lastfile_block" | grep -qE "\[ -f .+ \] \|\| exit 1" \
    && printf "%s\n" "$lastfile_block" | grep -q "head -c 32"'

# Every producer feeding a StdioCollector is capped at the source: nothing
# reaches a waitForEnd collector without a byte bound.
expect "backend output reaches QML through a bounded, exit-code-preserving pipe" \
  'grep -q "readonly property string backendScript" "$service" \
    && grep -q "set -o pipefail" "$service" \
    && grep -q "function backendCommand(args)" "$service" \
    && ! grep -q "command = \[\"bash\", backendPath" "$service" \
    && ! grep -q "command: \[\"bash\", root.backendPath" "$service"'
for s in pickScript trafficScript pingScript clipboardScript; do
  expect "$s caps its own output" \
    'printf "%s\n" "$(awk "/readonly property string '"$s"'/,/^\$/" "'"$service"'")" | grep -q "head -c"'
done

echo "----"
echo "$pass passed, $fail failed"
[ "$fail" = 0 ]

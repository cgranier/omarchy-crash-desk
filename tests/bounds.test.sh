#!/bin/bash
# Run with: bash tests/bounds.test.sh
# Runs Service.qml's own coredumpctl pipelines against a stub that floods
# stdout, and checks that what would reach the collector stays under the caps.
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
stub=$(mktemp -d)
trap 'rm -rf "$stub"' EXIT
cat > "$stub/coredumpctl" <<'STUB'
#!/bin/bash
# list: an endless JSON array; info: an endless backtrace.
if [[ $1 == list ]]; then
  printf '['; yes '{"pid":1,"uid":1000,"exe":"/usr/bin/x","sig":11,"time":1},' | head -c 50000000
else
  printf 'Stack trace of thread 1:\n'; yes '#0  0x0000000000001000 frame (libx.so + 0x10)' | head -c 50000000
fi
STUB
chmod +x "$stub/coredumpctl"
passed=0
ok() { passed=$((passed + 1)); echo "ok - $1"; }
cap() { node -e "process.stdout.write(String(require('$here/Model.js').$1))"; }

# The sh -c scripts exactly as Service.qml passes them.
script() { grep -o "'[^']*coredumpctl $1[^']*'" "$here/Service.qml" | head -1 | sed "s/^'//; s/'\$//"; }
list_script=$(script list)
info_script=$(script info)
[[ -n $list_script && -n $info_script ]]

bytes=$(PATH="$stub:$PATH" sh -c "$list_script" sh "" "$(cap LIST_MAX_ENTRIES)" "$(cap LIST_CAP_BYTES)" | wc -c)
(( bytes <= $(cap LIST_CAP_BYTES) + 16 ))
ok "list output is capped at LIST_CAP_BYTES ($bytes bytes)"

bytes=$(PATH="$stub:$PATH" sh -c "$info_script" sh 1 "$(cap INFO_CAP_BYTES)" | wc -c)
(( bytes <= $(cap INFO_CAP_BYTES) ))
ok "info output is capped at INFO_CAP_BYTES ($bytes bytes)"

# Every shell script Service.qml runs caps its output with head -c, except
# the one that pages `coredumpctl info` in a terminal (read by a person, not
# collected). The state helper is a python3 argv, capped at 64 KB by itself.
while read -r line; do
  [[ $line == *"head -c"* || $line == *"| less -R"* ]] || { echo "uncapped: $line" >&2; exit 1; }
done < <(grep -o "'[^']*'" "$here/Service.qml" | grep -vE "^'[^ ]*'\$")
ok "every collected shell script is capped"

echo "$passed passed"

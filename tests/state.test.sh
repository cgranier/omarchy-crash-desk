#!/bin/bash
# Tests for bin/crashdesk-state against planted files. Run with: bash tests/state.test.sh
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
S="$HERE/../bin/crashdesk-state"
T=$(mktemp -d); trap 'rm -rf "$T"; kill $(jobs -p) 2>/dev/null' EXIT
export HOME="$T/home"; mkdir -p "$HOME"; chmod 700 "$HOME"
D="$HOME/.local/state/omarchy-crashdesk"; F="$D/seen.json"
pass=0; fail=0
check() { if eval "$2"; then pass=$((pass + 1)); echo "ok - $1"; else fail=$((fail + 1)); echo "FAIL - $1"; fi; }
run() { timeout 5 python3 "$S" "$@"; }

out=$(run read "$F"); rc=$?
check "no file yet: prints {} and creates the directory 0700" '[[ $rc == 0 && $out == "{}" && $(stat -c %a "$D") == 700 ]]'
run write "$F" '{"version":2,"seenMs":5}'; rc=$?
check "write: exit 0, file is 0600 and reads back" '[[ $rc == 0 && $(stat -c %a "$F") == 600 && $(run read "$F") == "{\"version\":2,\"seenMs\":5}" ]]'
check "no temp file left behind" '[[ -z $(ls -A "$D" | grep -v "^seen.json$") ]]'

rm -f "$F"; ln -s /etc/passwd "$F"
out=$(run read "$F" 2>/dev/null); rc=$?
check "symlink at the path: read refuses (3), prints nothing" '[[ $rc == 3 && -z $out ]]'
run write "$F" '{}' 2>/dev/null; rc=$?
check "symlink at the path: write refuses, link untouched, target untouched" '[[ $rc == 3 && -L $F && $(readlink "$F") == /etc/passwd ]]'
rm -f "$F"

mkfifo "$F"; out=$(run read "$F" 2>/dev/null); rc=$?
check "FIFO at the path: read refuses without blocking" '[[ $rc == 3 ]]'
run write "$F" '{}' 2>/dev/null; rc=$?
check "FIFO at the path: write refuses" '[[ $rc == 3 && -p $F ]]'
rm -f "$F"

head -c 70000 /dev/zero | tr '\0' 'x' >"$F"; out=$(run read "$F" 2>/dev/null); rc=$?
check "oversized file: read refuses" '[[ $rc == 3 && -z $out ]]'
rm -f "$F"

big=$(head -c 70000 /dev/zero | tr '\0' 'y'); run write "$F" "$big" 2>/dev/null; rc=$?
check "oversized content: write refuses, nothing written" '[[ $rc == 3 && ! -e $F ]]'

rm -rf "$D"; ln -s "$T/elsewhere" "$D"; mkdir -p "$T/elsewhere"
run write "$F" '{}' 2>/dev/null; rc=$?
check "state directory is a symlink: refused" '[[ $rc == 3 && ! -e $T/elsewhere/seen.json ]]'
rm -f "$D"

mkdir -p "$D"; chmod 777 "$HOME/.local/state"
run read "$F" 2>/dev/null; rc=$?
check "an ancestor writable by others: refused" '[[ $rc == 3 ]]'
chmod 755 "$HOME/.local/state"

run read "$T/outside.json" 2>/dev/null; rc=$?
check "a path outside home: refused" '[[ $rc == 3 ]]'
run read 2>/dev/null; rc=$?
check "usage error: exit 1" '[[ $rc == 1 ]]'

echo; echo "$pass passed, $fail failed"; (( fail == 0 ))

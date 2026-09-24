#!/bin/sh
# Fixture 2 (contract item 2) — probe.sh Grok pre-approval, three states.
#
#   A. flag file present at $FOREMAN_HOME/grok-preapproved
#   B. no flag file, FOREMAN_GROK_PREAPPROVED=1 in the environment only
#   C. neither
#
# Asserts the v0.5 effort line appears in A and B and NOT in C, that the old
# fixed-effort wording is gone everywhere, and that the parallel ceiling is
# read from the flag file when present.
#
# The real flags are untouched by construction: probe.sh is run through `env -i`
# with HOME and FOREMAN_HOME pointed at a mktemp directory, so no code path in
# it can reach $HOME/.foreman. The fixture asserts that redirection explicitly
# rather than trusting it.
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/lib.sh"
SCRIPT="$HERE/../scripts/probe.sh"

EFFORT_LINE="grok effort: lead judgment per dispatch (no-evidence prior: highest supported)"
OLD_WORDING="grok-4.6 @ xhigh for implementation and review"

TMP=$(mktemp -d "${TMPDIR:-/tmp}/foreman-fx2.XXXXXX") || exit 1
trap 'rm -rf "$TMP"' EXIT INT TERM

FAKE_HOME="$TMP/home"
FAKE_FOREMAN="$FAKE_HOME/.foreman"
mkdir -p "$FAKE_FOREMAN"

# Guard: the temporary home must not be the real one. If this ever fails the
# fixture refuses to run rather than risk touching a real flag file.
case "$FAKE_FOREMAN" in
  "$HOME"/*) printf 'FAIL  2.0 temp HOME escaped into the real HOME (%s)\n' "$FAKE_FOREMAN"; exit 1 ;;
  *) pass "2.0 temp HOME is outside the real \$HOME" ;;
esac

# Minimal PATH keeps the run hermetic and fast: no codex/grok/jq binaries are
# discoverable, so the probe reports them absent and makes no external calls.
run_probe() { # run_probe <outfile> [extra env assignments...]
  _out=$1; shift
  env -i HOME="$FAKE_HOME" FOREMAN_HOME="$FAKE_FOREMAN" \
      PATH=/usr/bin:/bin:/usr/sbin:/sbin TMPDIR="$TMP" "$@" \
      sh "$SCRIPT" > "$_out" 2>"$_out.err"
}

# ---------------------------------------------------------------- state A
printf 'parallel: 7\n' > "$FAKE_FOREMAN/grok-preapproved"
( cd "$TMP" && run_probe "$TMP/a.out" )
assert_contains "2.A flag file present: effort line printed"     "$TMP/a.out" "$EFFORT_LINE"
assert_contains "2.A flag file present: ceiling read from flag"  "$TMP/a.out" "parallel ceiling 7 (reported default, not a measured maximum)"
assert_contains "2.A flag file present: PRE-APPROVED reported"   "$TMP/a.out" "grok billing: PRE-APPROVED"
assert_absent   "2.A old fixed-effort wording removed"           "$TMP/a.out" "$OLD_WORDING"
assert_absent   "2.A no bare xhigh claim remains"                "$TMP/a.out" "@ xhigh"

# ---------------------------------------------------------------- state B
rm -f "$FAKE_FOREMAN/grok-preapproved"
( cd "$TMP" && run_probe "$TMP/b.out" FOREMAN_GROK_PREAPPROVED=1 )
assert_contains "2.B env only: effort line printed"        "$TMP/b.out" "$EFFORT_LINE"
assert_contains "2.B env only: default ceiling 15"         "$TMP/b.out" "parallel ceiling 15 (reported default, not a measured maximum)"
assert_absent   "2.B old fixed-effort wording removed"     "$TMP/b.out" "$OLD_WORDING"

# ---------------------------------------------------------------- state C
( cd "$TMP" && run_probe "$TMP/c.out" )
assert_absent "2.C neither: no effort line"          "$TMP/c.out" "$EFFORT_LINE"
assert_absent "2.C neither: no PRE-APPROVED line"    "$TMP/c.out" "grok billing: PRE-APPROVED"
assert_contains "2.C neither: probe still completes" "$TMP/c.out" "== probe complete."

# ---------------------------------------------------------------- invariants
assert_contains "2.D probe still reports the sandbox rule" "$TMP/a.out" "grok sandbox: default is OFF"
if [ ! -e "$FAKE_FOREMAN/grok-preapproved" ]; then
  pass "2.D probe never re-created the flag file it read"
else
  fail "2.D probe never re-created the flag file it read"
fi
# The probe is read-only: the only thing it may have created under the fake home
# is nothing at all.
CREATED=$(find "$FAKE_HOME" -newer "$SCRIPT" -type f 2>/dev/null | wc -l | tr -d ' ')
assert_eq "2.D fake home holds no probe-written files" "0" "$CREATED"

finish "fixture 2 (probe)"

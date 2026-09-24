#!/bin/sh
# Fixture 4 (contract item 4) — Grok reviewer-to-fixer transition, LIVE.
#
# This is the runtime check behind the settled claim at grok-workers.md:146:
# a session created under the `read-only` sandbox CANNOT be resumed under
# `workspace`; the CLI refuses before any spend. Everything else in tests/ is
# hermetic and free — this one is not:
#
#   * IT MAKES REAL, BILLABLE GROK CALLS (~$0.01 for the two dispatches;
#     the observed run on 2026-09-07 cost $0.00604758 for step 1 and $0 for
#     step 2, which is refused before any model call).
#   * It therefore runs ONLY when FOREMAN_LIVE_GROK=1 is set AND the local
#     grok CLI reports being logged in. Otherwise it prints one SKIP line and
#     exits 0, so run-all.sh stays free and offline by default.
#
# It dispatches through the UNCHANGED launcher scripts/grok-dispatch.sh — the
# point is what the launcher plus the CLI actually do, so nothing here composes
# a grok command by hand.
#
# Scratch repo location: a mktemp directory under $HOME/Foreman-Skills (or $PWD),
# never under /tmp — the launcher's `read-only` sandbox profile refuses a
# workdir beneath /tmp, so a /tmp scratch repo cannot exercise step 1 at all.
#
# Recorded evidence from the observed run: tests/evidence/fixture-4-2026-09-07.md
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/lib.sh"
LAUNCHER="$HERE/../scripts/grok-dispatch.sh"

MODEL=${FOREMAN_GROK_MODEL:-grok-4.6}
EFFORT=low
REFUSAL="cannot resume this session under sandbox profile"

# ---------------------------------------------------------------- opt-in gate
if [ "${FOREMAN_LIVE_GROK:-}" != "1" ]; then
  printf 'SKIP fixture 4 (live Grok; set FOREMAN_LIVE_GROK=1)\n'
  printf -- '---- fixture 4 (grok transition): skipped, 0 passed, 0 failed\n'
  exit 0
fi

if [ -n "${GROK_BIN:-}" ]; then
  :
elif command -v grok >/dev/null 2>&1; then
  GROK_BIN=$(command -v grok)
else
  GROK_BIN="${GROK_HOME:-$HOME/.grok}/bin/grok"
fi

if [ ! -x "$GROK_BIN" ] || ! MODELS_OUT=$("$GROK_BIN" models 2>&1) || \
   ! printf '%s' "$MODELS_OUT" | grep -qi 'logged in'; then
  printf 'SKIP fixture 4 (live Grok; set FOREMAN_LIVE_GROK=1) — CLI not usable or not logged in\n'
  printf -- '---- fixture 4 (grok transition): skipped, 0 passed, 0 failed\n'
  exit 0
fi
printf 'live run: %s (%s)\n' "$GROK_BIN" "$("$GROK_BIN" --version 2>&1 | head -1)"

# ---------------------------------------------------------------- scratch repo
BASE="$HOME/Foreman-Skills"
[ -d "$BASE" ] && [ -w "$BASE" ] || BASE="$PWD"
case "$BASE" in /tmp/*|/private/tmp/*|/var/folders/*)
  printf 'FAIL  4.0 scratch base resolved under a temp dir (%s); the launcher refuses read-only there\n' "$BASE"
  exit 1 ;;
esac
WORK=$(mktemp -d "$BASE/.fx-XXXXXX") || exit 1
trap 'rm -rf "$WORK"' EXIT INT TERM
pass "4.0 scratch repo is outside /tmp ($WORK)"

( cd "$WORK" && git init -q . && git config user.email t@example.invalid && git config user.name t ) >/dev/null 2>&1
printf 'hello\n' > "$WORK/note.txt"
mkdir -p "$WORK/.foreman/scratch"
SCRATCH="$WORK/.foreman/scratch"

cat > "$SCRATCH/t1.md" <<'TICKET'
You are a read-only reviewer. Read note.txt in this directory and report its exact
contents. Then attempt to create a file named PROBE-RO.txt containing "written" in
this directory, and report honestly whether the write succeeded or which
tool/permission error you got. First line of your final message must be DONE or BLOCKED.
TICKET

cat > "$SCRATCH/t2.md" <<'TICKET'
This is a continuation of your previous session. Now create a file named PROBE-WS.txt
containing "written" in the working directory, then run `ls` and report whether
PROBE-WS.txt and PROBE-RO.txt exist. First line of your final message must be DONE or BLOCKED.
TICKET

# ---------------------------------------------------------------- step 1
printf '\n-- step 1: read-only reviewer dispatch --\n'
sh "$LAUNCHER" "$SCRATCH/t1.md" "$MODEL" "$EFFORT" read-only "$SCRATCH/a1.json" "$WORK" \
  > "$SCRATCH/e1.txt" 2>&1; RC1=$?
sed -n '1,12p' "$SCRATCH/e1.txt"
assert_eq "4.1 read-only dispatch exits 0" "0" "$RC1"
assert_file "4.1 step-1 artifact written" "$SCRATCH/a1.json"
if [ ! -e "$WORK/PROBE-RO.txt" ]; then
  pass "4.1 read-only reviewer created no PROBE-RO.txt"
else
  fail "4.1 read-only reviewer created no PROBE-RO.txt — a read-only seat WROTE to the workdir"
fi

SESSION=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("sessionId",""))' "$SCRATCH/a1.json" 2>/dev/null) || SESSION=""
if printf '%s' "$SESSION" | grep -Eq '^[A-Za-z0-9-]+$'; then
  pass "4.1 session id extracted from the artifact ($SESSION)"
else
  fail "4.1 session id extracted from the artifact (got [$SESSION])"
  finish "fixture 4 (grok transition)"
fi

# ---------------------------------------------------------------- step 2
printf '\n-- step 2: resume the same session on workspace --\n'
sh "$LAUNCHER" "$SCRATCH/t2.md" "$MODEL" "$EFFORT" workspace "$SCRATCH/a2.json" "$WORK" "$SESSION" \
  > "$SCRATCH/e2.txt" 2>&1; RC2=$?
sed -n '1,12p' "$SCRATCH/e2.txt"
printf 'step-2 stderr: '; cat "$SCRATCH/a2.json.stderr" 2>/dev/null; printf '\n'

if [ "$RC2" = "0" ] && [ -e "$WORK/PROBE-WS.txt" ]; then
  # The documented behaviour has changed on this build. Fail loudly: the claim
  # at grok-workers.md:146 and the transition path it settles must be revisited.
  printf 'OBSERVED CHANGE: cross-profile resume now permitted on this build\n'
  fail "4.2 cross-profile resume is refused — IT WAS PERMITTED; grok-workers.md:146 must be revisited"
else
  if [ "$RC2" != "0" ]; then
    pass "4.2 workspace resume of a read-only session exits non-zero (got $RC2)"
  else
    fail "4.2 workspace resume of a read-only session exits non-zero (got 0)"
  fi
  if grep -qF -- "$REFUSAL" "$SCRATCH/a2.json.stderr" 2>/dev/null || \
     grep -qF -- "$REFUSAL" "$SCRATCH/e2.txt" 2>/dev/null; then
    pass "4.2 refusal names the sandbox-profile mismatch"
  else
    fail "4.2 refusal names the sandbox-profile mismatch (expected [$REFUSAL])"
  fi
  if [ ! -e "$WORK/PROBE-WS.txt" ]; then
    pass "4.2 refused resume wrote nothing"
  else
    fail "4.2 refused resume wrote nothing — PROBE-WS.txt exists"
  fi
fi

printf '\nOBSERVED, not scripted: this fixture reports what the launcher and grok CLI\n'
printf 'actually did on this machine just now. See tests/evidence/fixture-4-2026-09-07.md\n'

finish "fixture 4 (grok transition)"

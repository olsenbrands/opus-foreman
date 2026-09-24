#!/bin/sh
# Fixture 3 (contract item 3, amendment 3) — crew-append.sh on a SCRATCH target.
#
# Cases, in order:
#   3.1 two concurrent appends both land exactly once
#   3.2 identical duplicate is a NOOP and writes nothing
#   3.3 same key, different content -> CONFLICT exit 76, nothing written,
#       receipt names both fingerprints
#   3.4 correction is a new record at rev+1 (prior record untouched)
#   3.5 read-only target -> non-zero exit and a retryable receipt
#   3.6 writer kill -9'd while holding the lock, pid now DEAD -> next call
#       reclaims and commits
#   3.7 lock owner pid is a LIVE process on this host -> bounded timeout,
#       exit 75, receipt naming the owner; lock left in place
#   3.8 writer kill -9'd mid-append -> trailing fragment quarantined, prior
#       complete records byte-identical (sha256 of the prefix), re-run commits
#       exactly one record
#   3.9 foreign-host lock (even with a dead pid) is NEVER reclaimed -> exit 75
#   3.10 the atomic replace that publishes the truncated copy fails -> target
#        byte-identical, the intact copy survives and is named in the receipt
#   3.11 kill -9 after the truncated copy is staged but BEFORE the rename ->
#        target still intact (never empty); next call recovers and commits one
#   3.12 the REAL `mv -f` publish step fails, with NO test hook: an ACL denying
#        `delete` on the target makes rename(2) return EACCES while the file
#        stays writable, so the genuine failure branch is exercised
#
# Every lock-path case also asserts a bounded return time.
#
# The target is always a file under one mktemp -d. This fixture never names
# $HOME/.foreman or the real crew-performance.md; run-all.sh additionally
# refuses to start if either could be reached.
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/lib.sh"
SCRIPT="$HERE/../scripts/crew-append.sh"

TMP=$(mktemp -d "${TMPDIR:-/tmp}/foreman-fx3.XXXXXX") || exit 1
cleanup_fx3() {
  # Kill any test-hook writer still parked in its sleep, then remove the tree.
  [ -n "${STRAY_PIDS:-}" ] && kill -9 $STRAY_PIDS 2>/dev/null
  chmod -R u+w "$TMP" 2>/dev/null
  rm -rf "$TMP"
}
trap cleanup_fx3 EXIT INT TERM
STRAY_PIDS=""

TARGET="$TMP/crew-performance.md"
RECEIPTS="$TMP/receipts"
HOSTNAME_NOW=$(hostname 2>/dev/null || uname -n)

export CREW_APPEND_RECEIPT_DIR="$RECEIPTS"
export CREW_APPEND_LOCK_WAIT=6
export CREW_APPEND_TEST_PAUSE_SECS=25

mkrec() { # mkrec <path> <run> <outcome> <rev> <body-text>
  { printf 'RECORD host=%s run=%s outcome=%s rev=%s\n' "$HOSTNAME_NOW" "$2" "$3" "$4"
    printf 'body: %s\n' "$5"
    printf 'disposition: accepted\nusage: unavailable\n'
  } > "$1"
}

# Plain calls only. NEVER write `VAR=1 run_append ...`: in POSIX sh an
# environment prefix on a FUNCTION persists in the calling shell after the
# function returns, so a test hook set that way leaks into every later case.
# Env-prefixed calls go through `env VAR=1 sh "$SCRIPT" ...` instead.
run_append() { sh "$SCRIPT" "$@"; }

# assert_bounded <name> <t0> <t1> <configured wait> — the helper must never
# block past its bound; 2s of slack covers process start-up and the poll sleep.
assert_bounded() {
  _el=$(( $3 - $2 ))
  if [ "$_el" -le "$(( $4 + 2 ))" ]; then
    pass "$1 (returned in ${_el}s, bound ${4}s+2)"
  else
    fail "$1 (returned in ${_el}s, bound ${4}s+2)"
  fi
}
n_records() { grep -c '^END fp=' "$TARGET" 2>/dev/null || true; }

# ---------------------------------------------------------------- 3.1
mkrec "$TMP/r1" run-aaa out-1 1 "first closure"
mkrec "$TMP/r2" run-bbb out-2 1 "second closure"
env CREW_APPEND_LOCK_WAIT=15 sh "$SCRIPT" "$TMP/r1" "$TARGET" > "$TMP/c1.out" 2>&1 &
P1=$!
env CREW_APPEND_LOCK_WAIT=15 sh "$SCRIPT" "$TMP/r2" "$TARGET" > "$TMP/c2.out" 2>&1 &
P2=$!
wait $P1; RC1=$?
wait $P2; RC2=$?
assert_eq "3.1 concurrent append A exit 0" "0" "$RC1"
assert_eq "3.1 concurrent append B exit 0" "0" "$RC2"
assert_contains "3.1 A reports APPENDED" "$TMP/c1.out" "APPENDED key=RECORD host=$HOSTNAME_NOW run=run-aaa outcome=out-1 rev=1"
assert_contains "3.1 B reports APPENDED" "$TMP/c2.out" "APPENDED key=RECORD host=$HOSTNAME_NOW run=run-bbb outcome=out-2 rev=1"
assert_eq "3.1 exactly two complete records" "2" "$(n_records)"
assert_eq "3.1 record A present exactly once" "1" "$(count_matches "$TARGET" "run=run-aaa outcome=out-1 rev=1 fp=")"
assert_eq "3.1 record B present exactly once" "1" "$(count_matches "$TARGET" "run=run-bbb outcome=out-2 rev=1 fp=")"
if [ ! -e "$TARGET.lock" ]; then pass "3.1 lock released after both writers"; else fail "3.1 lock released after both writers"; fi

# ---------------------------------------------------------------- 3.2
SHA_BEFORE=$(sha_of "$TARGET")
run_append "$TMP/r1" "$TARGET" > "$TMP/dup.out" 2>&1; RCD=$?
assert_eq "3.2 identical duplicate exit 0" "0" "$RCD"
assert_contains "3.2 identical duplicate reports NOOP" "$TMP/dup.out" "NOOP key=RECORD host=$HOSTNAME_NOW run=run-aaa outcome=out-1 rev=1"
assert_eq "3.2 duplicate wrote nothing" "$SHA_BEFORE" "$(sha_of "$TARGET")"

# ---------------------------------------------------------------- 3.3
mkrec "$TMP/r1-different" run-aaa out-1 1 "DIFFERENT content under the same key"
run_append "$TMP/r1-different" "$TARGET" > "$TMP/conf.out" 2>&1; RCC=$?
assert_eq "3.3 conflicting duplicate exit 76" "76" "$RCC"
assert_contains "3.3 conflict reported" "$TMP/conf.out" "CONFLICT key=RECORD host=$HOSTNAME_NOW run=run-aaa outcome=out-1 rev=1"
assert_eq "3.3 conflict wrote nothing" "$SHA_BEFORE" "$(sha_of "$TARGET")"
CONF_RECEIPT=$(ls -1t "$RECEIPTS"/crew-append-receipt-*.md 2>/dev/null | head -1)
assert_file "3.3 conflict left a receipt" "${CONF_RECEIPT:-/nonexistent}"
if [ -n "${CONF_RECEIPT:-}" ]; then
  EXIST_FP=$(sed -n 's/^RECORD host='"$HOSTNAME_NOW"' run=run-aaa outcome=out-1 rev=1 fp=//p' "$TARGET" | head -1)
  INCOMING_FP=$(sed -n 's/.*incoming-fp=\([0-9a-f]*\).*/\1/p' "$TMP/conf.out" | head -1)
  assert_contains "3.3 receipt names the existing fingerprint" "$CONF_RECEIPT" "existing fp:  $EXIST_FP"
  assert_contains "3.3 receipt names the incoming fingerprint" "$CONF_RECEIPT" "incoming fp:  $INCOMING_FP"
  assert_contains "3.3 receipt is marked retryable"            "$CONF_RECEIPT" "RETRYABLE:"
fi

# ---------------------------------------------------------------- 3.4
# A correction is a NEW record at rev+1 naming the prior key in its body. The
# body deliberately mentions the prior key mid-line; only line-leading "RECORD "
# would be a framing forgery, and that is refused separately.
cp "$TARGET" "$TMP/before-correction"
BEFORE_CORR_SHA=$(sha_of "$TMP/before-correction")
BEFORE_CORR_BYTES=$(wc -c < "$TMP/before-correction" | tr -d ' ')
mkrec "$TMP/r1-corr" run-aaa out-1 2 "correction of key [host=$HOSTNAME_NOW run=run-aaa outcome=out-1 rev=1] — cause reclassified"
run_append "$TMP/r1-corr" "$TARGET" > "$TMP/corr.out" 2>&1; RCR=$?
assert_eq "3.4 correction at rev=2 exit 0" "0" "$RCR"
assert_contains "3.4 correction appended" "$TMP/corr.out" "APPENDED key=RECORD host=$HOSTNAME_NOW run=run-aaa outcome=out-1 rev=2"
assert_eq "3.4 three complete records now" "3" "$(n_records)"
assert_eq "3.4 rev=1 record still present exactly once" "1" "$(count_matches "$TARGET" "run=run-aaa outcome=out-1 rev=1 fp=")"
head -c "$BEFORE_CORR_BYTES" "$TARGET" > "$TMP/after-correction-prefix"
assert_eq "3.4 prior records byte-identical after the correction" "$BEFORE_CORR_SHA" "$(sha_of "$TMP/after-correction-prefix")"

# A body line that would forge a record boundary is refused outright.
{ printf 'RECORD host=%s run=run-eee outcome=out-9 rev=1\n' "$HOSTNAME_NOW"; printf 'END fp=deadbeef\n'; } > "$TMP/r-forge"
SHA_FORGE=$(sha_of "$TARGET")
run_append "$TMP/r-forge" "$TARGET" > "$TMP/forge.out" 2>&1; RCG=$?
assert_eq "3.4b framing forgery in the body is refused (exit 2)" "2" "$RCG"
assert_eq "3.4b framing forgery wrote nothing" "$SHA_FORGE" "$(sha_of "$TARGET")"

# ---------------------------------------------------------------- 3.5
SHA_RO=$(sha_of "$TARGET")
chmod 444 "$TARGET"
if [ "$(id -u)" = "0" ]; then
  fail "3.5 SKIPPED — running as root, a read-only file is still writable"
else
  run_append "$TMP/r2" "$TARGET" > "$TMP/ro.out" 2>&1; RCO=$?
  if [ "$RCO" != "0" ]; then pass "3.5 read-only target exits non-zero (got $RCO)"; else fail "3.5 read-only target exits non-zero (got 0)"; fi
  RO_RECEIPT=$(ls -1t "$RECEIPTS"/crew-append-receipt-*.md 2>/dev/null | head -1)
  assert_file "3.5 read-only target left a receipt" "${RO_RECEIPT:-/nonexistent}"
  [ -n "${RO_RECEIPT:-}" ] && assert_contains "3.5 receipt says the target was not writable" "$RO_RECEIPT" "not writable"
  assert_eq "3.5 read-only target unchanged" "$SHA_RO" "$(sha_of "$TARGET")"
  if [ ! -e "$TARGET.lock" ]; then pass "3.5 lock released after the I/O failure"; else fail "3.5 lock released after the I/O failure"; fi
fi
chmod 644 "$TARGET"

# ---------------------------------------------------------------- 3.6
# A writer that really dies while holding the lock. The EXIT trap cannot run
# under SIGKILL, so the lock directory survives with a now-dead owner pid.
mkrec "$TMP/r3" run-ccc out-3 1 "third closure"
# Launched as `sh "$SCRIPT"` directly, never through a shell function: $! must
# be the crew-append.sh process itself, since that is the pid it writes into the
# lock owner file and the pid this case has to kill.
CREW_APPEND_TEST_PAUSE_AFTER_LOCK=1 sh "$SCRIPT" "$TMP/r3" "$TARGET" > "$TMP/hold.out" 2>&1 &
HOLDER=$!
STRAY_PIDS="$STRAY_PIDS $HOLDER"
if wait_until 5 '[ -f "$TARGET.lock/owner" ]'; then
  pass "3.6 test-hook writer took the lock"
else
  fail "3.6 test-hook writer took the lock"
fi
OWNER_PID=$(sed -n 's/^pid=//p' "$TARGET.lock/owner" 2>/dev/null | head -1)
assert_eq "3.6 owner file records the launched pid" "$HOLDER" "${OWNER_PID:-none}"
kill -9 "$HOLDER" 2>/dev/null
wait "$HOLDER" 2>/dev/null
if wait_until 5 '! kill -0 "$OWNER_PID" 2>/dev/null'; then
  pass "3.6 lock owner pid is provably dead"
else
  fail "3.6 lock owner pid is provably dead"
fi
if [ -d "$TARGET.lock" ]; then pass "3.6 killed writer left the lock behind"; else fail "3.6 killed writer left the lock behind"; fi
T6A=$(date +%s)
env CREW_APPEND_LOCK_WAIT=6 sh "$SCRIPT" "$TMP/r3" "$TARGET" > "$TMP/reclaim.out" 2>&1; RCK=$?
T6B=$(date +%s)
assert_eq "3.6 next call exits 0 after reclaiming" "0" "$RCK"
assert_bounded "3.6 reclaim path returned within the bound" "$T6A" "$T6B" 6
assert_contains "3.6 reclaim is reported"  "$TMP/reclaim.out" "RECLAIM stale lock"
assert_contains "3.6 record committed"     "$TMP/reclaim.out" "APPENDED key=RECORD host=$HOSTNAME_NOW run=run-ccc outcome=out-3 rev=1"
assert_eq "3.6 four complete records now"  "4" "$(n_records)"
assert_eq "3.6 committed exactly once"     "1" "$(count_matches "$TARGET" "run=run-ccc outcome=out-3 rev=1 fp=")"

# ---------------------------------------------------------------- 3.7
# Same host, but the owner pid is a LIVE process: never reclaimed, bounded wait.
sleep 25 &
LIVE=$!
STRAY_PIDS="$STRAY_PIDS $LIVE"
mkdir -p "$TARGET.lock"
printf 'pid=%s\nhost=%s\nstart=%s\n' "$LIVE" "$HOSTNAME_NOW" "1970-01-01T00:00:00Z" > "$TARGET.lock/owner"
SHA_LIVE=$(sha_of "$TARGET")
mkrec "$TMP/r4" run-ddd out-4 1 "fourth closure"
T0=$(date +%s)
env CREW_APPEND_LOCK_WAIT=2 sh "$SCRIPT" "$TMP/r4" "$TARGET" > "$TMP/live.out" 2>&1; RCL=$?
T1=$(date +%s)
assert_eq "3.7 live same-host owner: exit 75" "75" "$RCL"
assert_bounded "3.7 returned within the bound" "$T0" "$T1" 2
# The owner must be seen as alive by BOTH liveness tests the script uses:
# kill -0 alone is not proof of death (EPERM on another user's live process).
if kill -0 "$LIVE" 2>/dev/null; then pass "3.7 live owner detected by kill -0"; else fail "3.7 live owner detected by kill -0"; fi
if [ -n "$(ps -p "$LIVE" -o pid= 2>/dev/null)" ]; then pass "3.7 live owner detected by ps -p"; else fail "3.7 live owner detected by ps -p"; fi
assert_eq "3.7 nothing written" "$SHA_LIVE" "$(sha_of "$TARGET")"
if [ -d "$TARGET.lock" ]; then pass "3.7 live owner's lock left in place"; else fail "3.7 live owner's lock left in place"; fi
LIVE_RECEIPT=$(ls -1t "$RECEIPTS"/crew-append-receipt-*.md 2>/dev/null | head -1)
assert_file "3.7 timeout left a receipt" "${LIVE_RECEIPT:-/nonexistent}"
if [ -n "${LIVE_RECEIPT:-}" ]; then
  assert_contains "3.7 receipt names the live owner pid" "$LIVE_RECEIPT" "pid=$LIVE"
  assert_contains "3.7 receipt explains why not reclaimed" "$LIVE_RECEIPT" "owner pid still exists on this host"
fi
kill -9 "$LIVE" 2>/dev/null; wait "$LIVE" 2>/dev/null
rm -rf "$TARGET.lock"

# ---------------------------------------------------------------- 3.9
# Foreign-host lock, dead pid: never reclaimed even though the pid is not alive
# here, because the owner is not on this host.
mkdir -p "$TARGET.lock"
printf 'pid=%s\nhost=%s\nstart=%s\n' "999999" "some-other-mac.invalid" "1970-01-01T00:00:00Z" > "$TARGET.lock/owner"
SHA_FOREIGN=$(sha_of "$TARGET")
T9A=$(date +%s)
env CREW_APPEND_LOCK_WAIT=2 sh "$SCRIPT" "$TMP/r4" "$TARGET" > "$TMP/foreign.out" 2>&1; RCF=$?
T9B=$(date +%s)
assert_eq "3.9 foreign-host lock: exit 75" "75" "$RCF"
assert_bounded "3.9 foreign-host path returned within the bound" "$T9A" "$T9B" 2
assert_eq "3.9 foreign-host lock: nothing written" "$SHA_FOREIGN" "$(sha_of "$TARGET")"
if [ -d "$TARGET.lock" ]; then pass "3.9 foreign-host lock never removed"; else fail "3.9 foreign-host lock never removed"; fi
assert_absent "3.9 no reclaim attempted on a foreign host" "$TMP/foreign.out" "RECLAIM stale lock"
FOR_RECEIPT=$(ls -1t "$RECEIPTS"/crew-append-receipt-*.md 2>/dev/null | head -1)
[ -n "${FOR_RECEIPT:-}" ] && assert_contains "3.9 receipt names the foreign host" "$FOR_RECEIPT" "host=some-other-mac.invalid"
[ -n "${FOR_RECEIPT:-}" ] && assert_contains "3.9 receipt states the foreign-host rule" "$FOR_RECEIPT" "a foreign-host lock is never reclaimed"
rm -rf "$TARGET.lock"

# ---------------------------------------------------------------- 3.8
# Writer killed mid-append. Snapshot the intact prefix first so "prior complete
# records preserved byte-for-byte" is a sha256 comparison, not a claim.
cp "$TARGET" "$TMP/prefix.snapshot"
PREFIX_SHA=$(sha_of "$TMP/prefix.snapshot")
PREFIX_BYTES=$(wc -c < "$TMP/prefix.snapshot" | tr -d ' ')
RECORDS_BEFORE=$(n_records)

CREW_APPEND_TEST_PAUSE_MID_APPEND=1 sh "$SCRIPT" "$TMP/r4" "$TARGET" > "$TMP/torn.out" 2>&1 &
TORN=$!
STRAY_PIDS="$STRAY_PIDS $TORN"
if wait_until 5 'grep -q "run=run-ddd outcome=out-4 rev=1 fp=" "$TARGET"'; then
  pass "3.8 partial append landed in the target"
else
  fail "3.8 partial append landed in the target"
fi
TORN_OWNER=$(sed -n 's/^pid=//p' "$TARGET.lock/owner" 2>/dev/null | head -1)
assert_eq "3.8 mid-append owner file records the launched pid" "$TORN" "${TORN_OWNER:-none}"
kill -9 "$TORN" 2>/dev/null
wait "$TORN" 2>/dev/null
wait_until 5 '! kill -0 "$TORN" 2>/dev/null' || true
assert_eq "3.8 fragment is not a record (END count unchanged)" "$RECORDS_BEFORE" "$(n_records)"

T8A=$(date +%s)
env CREW_APPEND_LOCK_WAIT=6 sh "$SCRIPT" "$TMP/r4" "$TARGET" > "$TMP/recover.out" 2>&1; RCV=$?
T8B=$(date +%s)
assert_eq "3.8 re-run exits 0" "0" "$RCV"
assert_bounded "3.8 recovery path returned within the bound" "$T8A" "$T8B" 6
assert_contains "3.8 fragment quarantined" "$TMP/recover.out" "QUARANTINED incomplete fragment"
assert_contains "3.8 record then committed" "$TMP/recover.out" "APPENDED key=RECORD host=$HOSTNAME_NOW run=run-ddd outcome=out-4 rev=1"
assert_file "3.8 quarantine file exists" "$TARGET.quarantine"
assert_contains "3.8 quarantine holds the fragment header" "$TARGET.quarantine" "run=run-ddd outcome=out-4 rev=1 fp="
assert_contains "3.8 quarantine carries a note line" "$TARGET.quarantine" "quarantined incomplete fragment"
assert_eq "3.8 exactly one committed record for the key" "1" "$(count_matches "$TARGET" "run=run-ddd outcome=out-4 rev=1 fp=")"
assert_eq "3.8 exactly one more complete record" "$((RECORDS_BEFORE + 1))" "$(n_records)"
head -c "$PREFIX_BYTES" "$TARGET" > "$TMP/prefix.after"
assert_eq "3.8 prior complete records byte-identical" "$PREFIX_SHA" "$(sha_of "$TMP/prefix.after")"

# ---------------------------------------------------------------- 3.10
# The quarantine path replaces the target by atomic rename. If that publish step
# fails, the target must be untouched and the intact truncated copy must survive
# and be named in the receipt — never a half-emptied global record.
mkrec "$TMP/r5" run-fff out-5 1 "fifth closure"
add_fragment() { # append a header with no END: an incomplete fragment
  printf '\nRECORD host=%s run=frag-%s outcome=out-frag rev=1 fp=%s\n' \
    "$HOSTNAME_NOW" "$1" "0000000000000000000000000000000000000000000000000000000000000000" >> "$TARGET"
  printf 'partial body, writer died here\n' >> "$TARGET"
}
add_fragment a
SHA_PRE_REPLACE=$(sha_of "$TARGET")
RECORDS_PRE_REPLACE=$(n_records)
T10A=$(date +%s)
env CREW_APPEND_TEST_FAIL_REPLACE=1 CREW_APPEND_LOCK_WAIT=6 sh "$SCRIPT" "$TMP/r5" "$TARGET" > "$TMP/replacefail.out" 2>&1; RC10=$?
T10B=$(date +%s)
assert_eq "3.10 failed atomic replace exits 74" "74" "$RC10"
assert_bounded "3.10 failed replace returned within the bound" "$T10A" "$T10B" 6
assert_eq "3.10 target byte-identical after the failed replace" "$SHA_PRE_REPLACE" "$(sha_of "$TARGET")"
if [ -s "$TARGET" ]; then pass "3.10 target is never emptied"; else fail "3.10 target is never emptied"; fi
assert_eq "3.10 committed records intact" "$RECORDS_PRE_REPLACE" "$(n_records)"
TRUNC_KEPT=$(ls -1 "$TARGET".trunc.* 2>/dev/null | head -1)
assert_file "3.10 the intact truncated copy survives" "${TRUNC_KEPT:-/nonexistent}"
R10=$(ls -1t "$RECEIPTS"/crew-append-receipt-*.md 2>/dev/null | head -1)
assert_file "3.10 failed replace left a receipt" "${R10:-/nonexistent}"
if [ -n "${R10:-}" ] && [ -n "${TRUNC_KEPT:-}" ]; then
  assert_contains "3.10 receipt names the surviving copy" "$R10" "$TRUNC_KEPT"
  assert_contains "3.10 receipt says the target was not modified" "$R10" "The target was NOT modified"
fi
if [ -n "${TRUNC_KEPT:-}" ]; then
  assert_eq "3.10 the surviving copy holds only complete records" \
    "$RECORDS_PRE_REPLACE" "$(grep -c '^END fp=' "$TRUNC_KEPT" 2>/dev/null || true)"
fi

# ---------------------------------------------------------------- 3.11
# kill -9 after the truncated copy is staged and fsynced but BEFORE the rename.
# The target must still be the old, intact file — never empty, never partial.
SHA_PRE_KILL=$(sha_of "$TARGET")
CREW_APPEND_TEST_PAUSE_BEFORE_RENAME=1 sh "$SCRIPT" "$TMP/r5" "$TARGET" > "$TMP/prerename.out" 2>&1 &
PRE=$!
STRAY_PIDS="$STRAY_PIDS $PRE"
if wait_until 8 'grep -q "rename not yet issued" "$TMP/prerename.out"'; then
  pass "3.11 writer paused with the copy staged and the rename not issued"
else
  fail "3.11 writer paused with the copy staged and the rename not issued"
fi
kill -9 "$PRE" 2>/dev/null
wait "$PRE" 2>/dev/null
wait_until 5 '! kill -0 "$PRE" 2>/dev/null' || true
if [ -s "$TARGET" ]; then pass "3.11 target still non-empty after the kill"; else fail "3.11 target still non-empty after the kill"; fi
assert_eq "3.11 target byte-identical after the kill" "$SHA_PRE_KILL" "$(sha_of "$TARGET")"
RECORDS_PRE_RECOVER=$(n_records)
T11A=$(date +%s)
env CREW_APPEND_LOCK_WAIT=6 sh "$SCRIPT" "$TMP/r5" "$TARGET" > "$TMP/prerename-recover.out" 2>&1; RC11=$?
T11B=$(date +%s)
assert_eq "3.11 next call recovers and exits 0" "0" "$RC11"
assert_bounded "3.11 recovery returned within the bound" "$T11A" "$T11B" 6
assert_contains "3.11 fragment quarantined on recovery" "$TMP/prerename-recover.out" "QUARANTINED incomplete fragment"
assert_contains "3.11 record committed on recovery" "$TMP/prerename-recover.out" "APPENDED key=RECORD host=$HOSTNAME_NOW run=run-fff outcome=out-5 rev=1"
if [ -s "$TARGET" ]; then pass "3.11 target never empty through the whole sequence"; else fail "3.11 target never empty through the whole sequence"; fi
assert_eq "3.11 exactly one record committed" "1" "$(count_matches "$TARGET" "run=run-fff outcome=out-5 rev=1 fp=")"
assert_eq "3.11 exactly one more complete record" "$((RECORDS_PRE_RECOVER + 1))" "$(n_records)"
assert_eq "3.11 no fragment left in the target" "0" "$(count_matches "$TARGET" "outcome=out-frag")"
assert_contains "3.11 fragment lives in the quarantine file" "$TARGET.quarantine" "outcome=out-frag"

# ---------------------------------------------------------------- 3.12
# 3.10 forces the failure branch with a hook. This case exercises the REAL
# `mv -f` failure with no hook at all.
#
# Why an ACL and not chmod: rename(2) needs write permission on the DIRECTORY,
# so chmod 555 on the directory would make the script fail earlier (it could not
# write the quarantine file or the truncated copy) and would never reach the
# rename. `chflags uchg` on the target makes `test -w` false, so the script
# stops at its "target not writable" check instead. An ACL denying `delete` on
# the target leaves the file writable and the directory writable — the
# quarantine append and the truncated copy both succeed — and only the rename,
# which must unlink the old target, is refused. That is the branch under test.
FX312_READY=no
if command -v chmod >/dev/null 2>&1 && chmod +a "$(id -un) deny delete" "$TARGET" 2>/dev/null; then
  if [ -w "$TARGET" ]; then FX312_READY=yes; else chmod -a# 0 "$TARGET" 2>/dev/null; fi
fi

if [ "$FX312_READY" != "yes" ]; then
  # Deliberately not the string "SKIP " at line start: run-all.sh reads that as
  # a whole-fixture skip.
  printf 'NOTE  3.12 not run — this platform does not support an ACL denying delete
'
else
  add_fragment b
  SHA_PRE_MV=$(sha_of "$TARGET")
  RECORDS_PRE_MV=$(n_records)
  QUAR_PRE_MV=0
  [ -f "$TARGET.quarantine" ] && QUAR_PRE_MV=$(wc -c < "$TARGET.quarantine" | tr -d ' ')
  mkrec "$TMP/r6" run-ggg out-6 1 "sixth closure"
  T12A=$(date +%s)
  env CREW_APPEND_LOCK_WAIT=6 sh "$SCRIPT" "$TMP/r6" "$TARGET" > "$TMP/mvfail.out" 2>&1; RC12=$?
  T12B=$(date +%s)
  assert_eq "3.12 real mv failure exits 74" "74" "$RC12"
  assert_bounded "3.12 real mv failure returned within the bound" "$T12A" "$T12B" 6
  assert_absent "3.12 no test hook was used" "$TMP/mvfail.out" "TEST-HOOK"
  assert_contains "3.12 the publish step is what failed" "$TMP/mvfail.out" "could not publish the truncated copy"
  assert_eq "3.12 target byte-identical after the failed mv" "$SHA_PRE_MV" "$(sha_of "$TARGET")"
  if [ -s "$TARGET" ]; then pass "3.12 target is never emptied"; else fail "3.12 target is never emptied"; fi
  assert_eq "3.12 committed records intact" "$RECORDS_PRE_MV" "$(n_records)"
  assert_eq "3.12 the incoming record was NOT committed" "0" "$(count_matches "$TARGET" "run=run-ggg outcome=out-6 rev=1 fp=")"
  MV_TRUNC=$(ls -1 "$TARGET".trunc.* 2>/dev/null | head -1)
  assert_file "3.12 the intact truncated copy survives" "${MV_TRUNC:-/nonexistent}"
  R12=$(ls -1t "$RECEIPTS"/crew-append-receipt-*.md 2>/dev/null | head -1)
  assert_file "3.12 real mv failure left a receipt" "${R12:-/nonexistent}"
  if [ -n "${R12:-}" ] && [ -n "${MV_TRUNC:-}" ]; then
    assert_contains "3.12 receipt names the surviving copy" "$R12" "$MV_TRUNC"
    assert_contains "3.12 receipt says the target was not modified" "$R12" "The target was NOT modified"
  fi
  if [ -n "${MV_TRUNC:-}" ]; then
    assert_eq "3.12 the surviving copy holds only complete records" \
      "$RECORDS_PRE_MV" "$(grep -c '^END fp=' "$MV_TRUNC" 2>/dev/null || true)"
  fi
  QUAR_POST_MV=$(wc -c < "$TARGET.quarantine" | tr -d ' ')
  if [ "$QUAR_POST_MV" -gt "$QUAR_PRE_MV" ]; then
    pass "3.12 the fragment reached the quarantine file before the failure"
  else
    fail "3.12 the fragment reached the quarantine file before the failure"
  fi

  # Drop the ACL, then prove the very same call succeeds once the cause is gone.
  chmod -a# 0 "$TARGET" 2>/dev/null
  rm -f "$TARGET".trunc.*
  env CREW_APPEND_LOCK_WAIT=6 sh "$SCRIPT" "$TMP/r6" "$TARGET" > "$TMP/mvfail-retry.out" 2>&1; RC12B=$?
  assert_eq "3.12 retry after the cause is fixed exits 0" "0" "$RC12B"
  assert_eq "3.12 retry commits exactly one record" "1" "$(count_matches "$TARGET" "run=run-ggg outcome=out-6 rev=1 fp=")"
  assert_eq "3.12 no fragment left in the target" "0" "$(count_matches "$TARGET" "outcome=out-frag")"
fi

# ---------------------------------------------------------------- invariants
# No test hook may have leaked into this shell (see the run_append note above).
LEAKED=""
for V in CREW_APPEND_TEST_FAIL_REPLACE CREW_APPEND_TEST_PAUSE_BEFORE_RENAME \
         CREW_APPEND_TEST_PAUSE_AFTER_LOCK CREW_APPEND_TEST_PAUSE_MID_APPEND; do
  eval "_v=\${$V:-}"
  [ -z "$_v" ] || LEAKED="$LEAKED $V"
done
assert_eq "3.X no test hook leaked into the fixture shell" "" "$LEAKED"

if [ -z "$(ls -1 "$TMP"/crew-performance.md.trunc.* 2>/dev/null)" ]; then
  pass "3.X no orphaned truncated copies left behind"
else
  fail "3.X no orphaned truncated copies left behind"
fi
if [ -z "$(ls -1 "$TMP"/crew-performance.md.staging.* 2>/dev/null)" ]; then
  pass "3.X no staging files left behind"
else
  fail "3.X no staging files left behind"
fi
if [ ! -e "$TARGET.lock" ]; then pass "3.X no lock left behind"; else fail "3.X no lock left behind"; fi

finish "fixture 3 (crew-append)"

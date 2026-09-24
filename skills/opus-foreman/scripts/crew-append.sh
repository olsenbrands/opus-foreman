#!/bin/sh
# opus-foreman — global crew-performance record: serialized, crash-safe append.
#
# Usage: crew-append.sh <record-file> [target]
#
#   <record-file>  A prepared closure record. Line 1 MUST be the record key:
#                    RECORD host=<h> run=<r> outcome=<o> rev=<n>
#                  Lines 2..EOF are the body (free text). No body line may
#                  start with "RECORD " or "END fp=" — that would forge the
#                  framing of a neighbouring record, so it is refused (exit 2).
#   [target]       Defaults to ${FOREMAN_HOME:-$HOME/.foreman}/crew-performance.md
#
# WHAT IT WRITES
#   One self-delimited block, appended and never rewritten:
#     RECORD host=<h> run=<r> outcome=<o> rev=<n> fp=<sha256>
#     <body>
#     END fp=<sha256>
#   A block without its matching END line is an incomplete fragment, never a
#   record. Corrections are NEW records with a higher rev= that name the prior
#   key in their body; no existing byte of the target is ever rewritten.
#
# FINGERPRINT
#   sha256 of the normalized framing content (key line + body, one trailing
#   newline per line). Computed with `shasum -a 256` when present, else
#   python3 hashlib.sha256. If neither exists the script fails loudly (exit 2)
#   rather than appending an unverifiable record.
#
# LOCKING
#   Lock is the directory <target>.lock holding an `owner` file with
#   pid=, host=, start=. Directory creation is the atomic test-and-set (no
#   flock(1) or GNU timeout is assumed; this runs on macOS /bin/sh).
#   Acquisition is bounded: CREW_APPEND_LOCK_WAIT seconds, default 30. On
#   timeout the script exits 75 and writes a retryable receipt naming the lock
#   owner. Closure never blocks indefinitely.
#
# STALE-OWNER RECLAIM
#   A lock is reclaimed ONLY when the owner file records this same host AND the
#   owner pid is gone by TWO independent tests: `kill -0 <pid>` fails AND
#   `ps -p <pid>` lists nothing. `kill -0` alone is not proof of death — it also
#   fails with EPERM for a live process owned by another user, which is
#   indistinguishable from ESRCH at the shell. Either test reporting the process
#   present means alive, so the lock is left where it is. A lock owned by another
#   host is NEVER reclaimed, no matter how old. Known limitation: pid reuse on
#   this host could make a dead owner look alive; that is the safe direction.
#
# INTERRUPTED-APPEND RECOVERY
#   Under the lock, the tail of the target is scanned. Anything after the last
#   complete "END fp=" line (a header with no END, or a half-written line) is
#   moved to <target>.quarantine with a note line, and the target is truncated
#   back to that last complete END. All prior complete records are preserved
#   byte-for-byte. A fragment is never treated as an already-applied closure,
#   so re-running after an interruption commits exactly one complete record.
#   The truncated copy is published by atomic rename (mv), never by truncating
#   the live file: `>` would empty the target before the copy finished, so a
#   kill or an I/O error mid-copy would destroy every committed record. Rename
#   changes the target's inode, so any pre-existing hard link to the old file
#   keeps the OLD content and does not follow the update — acceptable here (the
#   global record is addressed by path, not by link), but noted.
#   The lock holder also reaps <target>.staging.<pid> and <target>.trunc.<pid>
#   files left by writers that were SIGKILLed before their EXIT trap ran, but
#   only when that pid is gone by both liveness tests above.
#
# DURABILITY
#   The block is written to <target>.staging.<pid>, fsynced, appended to the
#   target, and the target is fsynced again; only then is APPENDED printed.
#   fsync is issued via python3 os.fsync when python3 exists, otherwise the
#   script falls back to sync(8), which is weaker (whole-filesystem flush
#   request, not a per-file barrier). Note that on macOS even os.fsync does not
#   guarantee the drive has flushed its own cache — that needs F_FULLFSYNC —
#   so this is durability against process death, not against power loss.
#
# DUPLICATES AND CONFLICTS
#   Identical key + identical fp already present -> prints NOOP, exit 0.
#   Identical key + different fp                -> prints CONFLICT, exit 76,
#   nothing written, receipt naming both fingerprints. Never a silent overwrite.
#
# RECEIPTS
#   Written to ${CREW_APPEND_RECEIPT_DIR:-.foreman}/crew-append-receipt-<utc>-<pid>.md
#   on every non-zero outcome (lock timeout, conflict, I/O failure).
#
# EXIT CODES
#   0  APPENDED | NOOP
#   2  usage / validation / missing hashing tool
#   74 I/O failure (unwritable target, staging or append failed) + receipt
#   75 bounded lock acquisition timed out + receipt naming the owner
#   76 duplicate key with different content + receipt naming both fingerprints
#
# TEST HOOKS (inert unless the variable is set to 1; for tests/ only)
#   CREW_APPEND_TEST_PAUSE_AFTER_LOCK=1
#       After the lock is taken and the owner file written, sleep
#       ${CREW_APPEND_TEST_PAUSE_SECS:-3600} so a test can kill -9 a process
#       that provably holds the lock.
#   CREW_APPEND_TEST_PAUSE_MID_APPEND=1
#       Append ONLY the framing header line to the target, fsync it, then sleep
#       ${CREW_APPEND_TEST_PAUSE_SECS:-3600}, simulating a writer killed
#       part-way through the append. Leaves exactly the fragment the recovery
#       path is required to quarantine.
#   CREW_APPEND_TEST_PAUSE_BEFORE_RENAME=1
#       During fragment quarantine, stop after <target>.trunc.<pid> is written
#       and fsynced but BEFORE the atomic rename that publishes it, then sleep
#       ${CREW_APPEND_TEST_PAUSE_SECS:-3600}. A kill here must leave the target
#       intact (old content), never empty.
#   CREW_APPEND_TEST_FAIL_REPLACE=1
#       Force the atomic-rename step to fail, exercising the branch that keeps
#       the intact copy, names it in the receipt and exits 74.
#   CREW_APPEND_LOCK_WAIT=<seconds>  Bounded wait override (default 30).
#
# No cross-machine synchronization is assumed. No database. Read-only callers
# should read the file directly; this script only ever appends.
set -eu

PROG=crew-append.sh

die() { printf '%s: ERROR: %s\n' "$PROG" "$*" >&2; exit 2; }

if [ "$#" -lt 1 ] || [ "$#" -gt 2 ]; then
  printf 'usage: %s <record-file> [target]\n' "$PROG" >&2
  exit 2
fi

RECORD_FILE=$1
TARGET=${2:-${FOREMAN_HOME:-$HOME/.foreman}/crew-performance.md}

[ -f "$RECORD_FILE" ] || die "record file not found: $RECORD_FILE"
[ -s "$RECORD_FILE" ] || die "record file is empty: $RECORD_FILE"

HOST=$(hostname 2>/dev/null) || HOST=$(uname -n)
[ -n "$HOST" ] || HOST="unknown-host"

# ---- header/key validation -------------------------------------------------
KEY=$(sed -n '1p' "$RECORD_FILE" | tr -d '\r' | sed 's/[[:space:]]*$//')
printf '%s\n' "$KEY" | grep -Eq '^RECORD host=[^[:space:]]+ run=[^[:space:]]+ outcome=[^[:space:]]+ rev=[0-9]+$' \
  || die "line 1 of $RECORD_FILE is not a valid record key.
  expected: RECORD host=<h> run=<r> outcome=<o> rev=<n>
  found:    $KEY"

if sed -n '2,$p' "$RECORD_FILE" | grep -Eq '^(RECORD |END fp=)'; then
  die "record body contains a framing line (^RECORD or ^END fp=) — refusing, it would forge a record boundary"
fi

# ---- fingerprint -----------------------------------------------------------
TMPDIR_BASE=$(dirname "$TARGET")
mkdir -p "$TMPDIR_BASE" 2>/dev/null || die "cannot create target directory: $TMPDIR_BASE"

NORM=$(mktemp "${TMPDIR:-/tmp}/crew-append-norm.XXXXXX") || die "mktemp failed"
NORM_CLEAN=$NORM
{
  printf '%s\n' "$KEY"
  sed -n '2,$p' "$RECORD_FILE"
} > "$NORM"

if command -v shasum >/dev/null 2>&1; then
  FP=$(shasum -a 256 "$NORM" | awk '{print $1}')
elif command -v python3 >/dev/null 2>&1; then
  FP=$(python3 -c 'import hashlib,sys;print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$NORM")
else
  rm -f "$NORM"
  die "no sha256 tool (need shasum or python3) — refusing to append an unfingerprinted record"
fi
[ -n "$FP" ] || { rm -f "$NORM"; die "fingerprint computation produced no output"; }

# ---- durability helper -----------------------------------------------------
PY3=$(command -v python3 2>/dev/null) || PY3=""
FSYNC_MECHANISM="python3 os.fsync"
[ -n "$PY3" ] || FSYNC_MECHANISM="sync(8) fallback (python3 absent)"

fsync_file() {
  if [ -n "$PY3" ]; then
    "$PY3" -c 'import os,sys
fd=os.open(sys.argv[1],os.O_RDONLY)
try:
    os.fsync(fd)
finally:
    os.close(fd)' "$1" 2>/dev/null || sync
  else
    sync
  fi
}

# ---- liveness --------------------------------------------------------------
# `kill -0` failing is NOT proof of death: it also fails with EPERM for a live
# process owned by another user. Two independent tests; either one reporting the
# process present means alive.
pid_alive() {
  [ -n "${1:-}" ] || return 1
  kill -0 "$1" 2>/dev/null && return 0
  [ -n "$(ps -p "$1" -o pid= 2>/dev/null)" ] && return 0
  return 1
}

fsync_dir() {
  if [ -n "$PY3" ]; then
    "$PY3" -c 'import os,sys
fd=os.open(sys.argv[1],os.O_RDONLY)
try:
    os.fsync(fd)
finally:
    os.close(fd)' "$1" 2>/dev/null || sync
  else
    sync
  fi
}

# ---- receipts --------------------------------------------------------------
RECEIPT_DIR=${CREW_APPEND_RECEIPT_DIR:-.foreman}
RECEIPT_PATH=""

write_receipt() {
  _kind=$1
  _detail=$2
  mkdir -p "$RECEIPT_DIR" 2>/dev/null || { printf '%s: WARNING: cannot create receipt dir %s\n' "$PROG" "$RECEIPT_DIR" >&2; return 0; }
  RECEIPT_PATH="$RECEIPT_DIR/crew-append-receipt-$(date -u +%Y%m%dT%H%M%SZ)-$$.md"
  {
    printf '# crew-append receipt — %s\n\n' "$_kind"
    printf -- '- when: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf -- '- this host: %s\n' "$HOST"
    printf -- '- this pid: %s\n' "$$"
    printf -- '- target: %s\n' "$TARGET"
    printf -- '- record key: %s\n' "$KEY"
    printf -- '- fingerprint: %s\n' "$FP"
    printf -- '- record file: %s\n' "$RECORD_FILE"
    printf '\n%s\n' "$_detail"
    printf '\nRETRYABLE: nothing was written to the target. Re-run:\n'
    printf '  %s %s %s\n' "$PROG" "$RECORD_FILE" "$TARGET"
  } > "$RECEIPT_PATH" 2>/dev/null || { printf '%s: WARNING: could not write receipt to %s\n' "$PROG" "$RECEIPT_PATH" >&2; RECEIPT_PATH=""; return 0; }
  printf 'RECEIPT %s\n' "$RECEIPT_PATH"
}

# ---- lock ------------------------------------------------------------------
LOCKDIR="$TARGET.lock"
OWNER_FILE="$LOCKDIR/owner"
STAGING="$TARGET.staging.$$"
HELD=0

cleanup() {
  _rc=$?
  [ -n "$NORM_CLEAN" ] && rm -f "$NORM_CLEAN" 2>/dev/null || true
  rm -f "$STAGING" 2>/dev/null || true
  if [ "$HELD" = "1" ]; then
    rm -f "$OWNER_FILE" 2>/dev/null || true
    rmdir "$LOCKDIR" 2>/dev/null || true
    HELD=0
  fi
  exit "$_rc"
}
trap cleanup EXIT INT TERM HUP

owner_field() {
  # $1 = field name; prints value or empty. Missing owner file -> empty.
  sed -n "s/^$1=//p" "$OWNER_FILE" 2>/dev/null | head -1
}

LOCK_WAIT=${CREW_APPEND_LOCK_WAIT:-30}
case "$LOCK_WAIT" in
  ''|*[!0-9]*) die "CREW_APPEND_LOCK_WAIT must be a whole number of seconds, got: $LOCK_WAIT" ;;
esac

START_EPOCH=$(date +%s)
while :; do
  if mkdir "$LOCKDIR" 2>/dev/null; then
    printf 'pid=%s\nhost=%s\nstart=%s\n' "$$" "$HOST" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$OWNER_FILE"
    HELD=1
    break
  fi

  O_PID=$(owner_field pid)
  O_HOST=$(owner_field host)
  O_START=$(owner_field start)

  # Reclaim ONLY a provably dead owner on this same host.
  if [ -n "$O_PID" ] && [ "$O_HOST" = "$HOST" ] && ! pid_alive "$O_PID"; then
    # Re-read under the same name to reduce the chance of removing a lock that
    # was just re-taken by a live process between our read and our remove.
    if [ "$(owner_field pid)" = "$O_PID" ] && ! pid_alive "$O_PID"; then
      printf 'RECLAIM stale lock (owner pid=%s host=%s start=%s is not alive on this host)\n' "$O_PID" "$O_HOST" "${O_START:-unknown}"
      rm -f "$OWNER_FILE" 2>/dev/null || true
      rmdir "$LOCKDIR" 2>/dev/null || true
    fi
  fi

  NOW=$(date +%s)
  if [ "$((NOW - START_EPOCH))" -ge "$LOCK_WAIT" ]; then
    printf 'TIMEOUT waiting %ss for lock %s (owner pid=%s host=%s start=%s)\n' \
      "$LOCK_WAIT" "$LOCKDIR" "${O_PID:-unknown}" "${O_HOST:-unknown}" "${O_START:-unknown}" >&2
    write_receipt "lock acquisition timed out" \
"Lock directory: $LOCKDIR
Lock owner (not reclaimed): pid=${O_PID:-unknown} host=${O_HOST:-unknown} start=${O_START:-unknown}
Reason not reclaimed: $( [ "${O_HOST:-}" != "$HOST" ] && printf 'owner is on a different host — a foreign-host lock is never reclaimed' || printf 'owner pid still exists on this host (kill -0 and/or ps report it present)' ).
Waited: ${LOCK_WAIT}s (CREW_APPEND_LOCK_WAIT)."
    exit 75
  fi
  sleep 0.2 2>/dev/null || sleep 1
done

# ---- orphaned staging files (under the lock) -------------------------------
# Staging files are only ever written by the lock holder, so any <target>.staging.<pid>
# other than ours belongs to a writer that died before its EXIT trap could run
# (SIGKILL). Reap only the ones whose pid is provably not alive here, so a live
# writer's file is never removed.
for _stale in "$TARGET".staging.* "$TARGET".trunc.*; do
  [ -e "$_stale" ] || continue
  _spid=${_stale##*.}
  [ "$_spid" = "$$" ] && continue
  case "$_spid" in ''|*[!0-9]*) continue ;; esac
  pid_alive "$_spid" || rm -f "$_stale"
done

# ---- interrupted-append recovery (under the lock) --------------------------
if [ -e "$TARGET" ]; then
  [ -f "$TARGET" ] || { printf '%s: ERROR: target exists and is not a regular file: %s\n' "$PROG" "$TARGET" >&2; write_receipt "target is not a regular file" "Target: $TARGET"; exit 74; }
  if [ ! -w "$TARGET" ]; then
    printf '%s: ERROR: target is not writable: %s\n' "$PROG" "$TARGET" >&2
    write_receipt "target not writable" \
"Target $TARGET exists but is not writable by this process (uid $(id -u)).
No lock was left behind and nothing was written."
    exit 74
  fi

  # Last complete record boundary. Everything after it is, by definition, an
  # incomplete fragment: a header with no END, or a half-written line. sed
  # emits an unterminated final line too, so a torn write is still seen.
  LAST_END=$(grep -n '^END fp=' "$TARGET" | tail -1 | cut -d: -f1) || LAST_END=""
  [ -n "${LAST_END:-}" ] || LAST_END=0
  TAIL_CONTENT=$(sed -n "$((LAST_END + 1)),\$p" "$TARGET" | grep -c . || true)
  [ -n "$TAIL_CONTENT" ] || TAIL_CONTENT=0

  if [ "$TAIL_CONTENT" -gt 0 ]; then
    QUAR="$TARGET.quarantine"
    {
      printf '\n# quarantined incomplete fragment — %s — by %s pid %s on %s\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$PROG" "$$" "$HOST"
      printf '# source: %s, line %s..EOF (no matching "END fp=" line; never a record)\n' \
        "$TARGET" "$((LAST_END + 1))"
      sed -n "$((LAST_END + 1)),\$p" "$TARGET"
    } >> "$QUAR" 2>/dev/null || {
      printf '%s: ERROR: cannot write quarantine file %s\n' "$PROG" "$QUAR" >&2
      write_receipt "quarantine write failed" "Could not append the trailing fragment to $QUAR; target left untouched."
      exit 74
    }
    # Build the truncated copy beside the target, then publish it by atomic
    # rename. Never `> "$TARGET"`: that empties the live file first, so a kill
    # or an I/O error mid-copy would destroy every committed record.
    TRUNC="$TARGET.trunc.$$"
    if [ "$LAST_END" -gt 0 ]; then
      sed -n "1,${LAST_END}p" "$TARGET" > "$TRUNC" 2>/dev/null || {
        printf '%s: ERROR: cannot write truncated copy %s\n' "$PROG" "$TRUNC" >&2
        write_receipt "truncated-copy write failed" "Target $TARGET was NOT modified. The fragment is recorded in $TARGET.quarantine."
        exit 74
      }
    else
      : > "$TRUNC"
    fi
    # Carry the target's mode across the rename (BSD and GNU stat differ).
    T_MODE=$(stat -f '%Lp' "$TARGET" 2>/dev/null) || T_MODE=$(stat -c '%a' "$TARGET" 2>/dev/null) || T_MODE=""
    [ -n "$T_MODE" ] && chmod "$T_MODE" "$TRUNC" 2>/dev/null
    fsync_file "$TRUNC"

    # TEST HOOK: inert unless CREW_APPEND_TEST_PAUSE_BEFORE_RENAME=1.
    if [ "${CREW_APPEND_TEST_PAUSE_BEFORE_RENAME:-}" = "1" ]; then
      printf 'TEST-HOOK truncated copy staged, rename not yet issued, pid %s\n' "$$"
      sleep "${CREW_APPEND_TEST_PAUSE_SECS:-3600}"
    fi

    # TEST HOOK: CREW_APPEND_TEST_FAIL_REPLACE=1 forces the failure branch.
    if [ "${CREW_APPEND_TEST_FAIL_REPLACE:-}" = "1" ] || ! mv -f "$TRUNC" "$TARGET" 2>/dev/null; then
      printf '%s: ERROR: could not publish the truncated copy over %s\n' "$PROG" "$TARGET" >&2
      write_receipt "atomic replace after quarantine failed" \
"The target was NOT modified and is byte-identical to what it held on entry.
The intact truncated copy is kept for recovery at:
  $TRUNC
The fragment is already recorded in $TARGET.quarantine. Recover by hand with:
  mv -f \"$TRUNC\" \"$TARGET\"
or simply re-run this command once the cause (permissions, disk) is fixed."
      exit 74
    fi
    fsync_file "$TARGET"
    fsync_dir "$TMPDIR_BASE"
    printf 'QUARANTINED incomplete fragment (%s lines) -> %s\n' "$TAIL_CONTENT" "$QUAR"
  fi
fi

# ---- duplicate / conflict --------------------------------------------------
EXISTING_FP=""
if [ -f "$TARGET" ]; then
  EXISTING_FP=$(KEYPAT="$KEY fp=" awk '
    index($0, ENVIRON["KEYPAT"]) == 1 { print substr($0, length(ENVIRON["KEYPAT"]) + 1) }
  ' "$TARGET" | tail -1)
fi

if [ -n "$EXISTING_FP" ]; then
  if [ "$EXISTING_FP" = "$FP" ]; then
    printf 'NOOP key=%s fp=%s (identical record already present in %s)\n' "$KEY" "$FP" "$TARGET"
    exit 0
  fi
  printf 'CONFLICT key=%s existing-fp=%s incoming-fp=%s — nothing written\n' "$KEY" "$EXISTING_FP" "$FP" >&2
  write_receipt "duplicate key with different content" \
"The target already holds this record key with a DIFFERENT fingerprint.
  key:          $KEY
  existing fp:  $EXISTING_FP
  incoming fp:  $FP
Nothing was written. Records are never rewritten: resolve by appending a
correction record with a higher rev= that names the key above in its body."
  exit 76
fi

# ---- staged, fsynced append ------------------------------------------------
LEAD_BLANK=""
if [ -s "$TARGET" ]; then LEAD_BLANK="yes"; fi

{
  [ -n "$LEAD_BLANK" ] && printf '\n'
  printf '%s fp=%s\n' "$KEY" "$FP"
  sed -n '2,$p' "$RECORD_FILE"
  printf 'END fp=%s\n' "$FP"
} > "$STAGING" 2>/dev/null || {
  printf '%s: ERROR: cannot write staging file %s\n' "$PROG" "$STAGING" >&2
  write_receipt "staging write failed" "Could not write $STAGING; nothing appended."
  exit 74
}
fsync_file "$STAGING"

# TEST HOOK: inert unless CREW_APPEND_TEST_PAUSE_AFTER_LOCK=1.
if [ "${CREW_APPEND_TEST_PAUSE_AFTER_LOCK:-}" = "1" ]; then
  printf 'TEST-HOOK holding lock, pid %s\n' "$$"
  sleep "${CREW_APPEND_TEST_PAUSE_SECS:-3600}"
fi

# TEST HOOK: inert unless CREW_APPEND_TEST_PAUSE_MID_APPEND=1. Appends only the
# framing header, leaving exactly the fragment the recovery path must quarantine.
if [ "${CREW_APPEND_TEST_PAUSE_MID_APPEND:-}" = "1" ]; then
  {
    [ -n "$LEAD_BLANK" ] && printf '\n'
    printf '%s fp=%s\n' "$KEY" "$FP"
  } >> "$TARGET"
  fsync_file "$TARGET"
  printf 'TEST-HOOK partial append written, pid %s\n' "$$"
  sleep "${CREW_APPEND_TEST_PAUSE_SECS:-3600}"
fi

if ! { cat "$STAGING" >> "$TARGET"; } 2>/dev/null; then
  printf '%s: ERROR: append to %s failed\n' "$PROG" "$TARGET" >&2
  write_receipt "append failed" "Appending the staged block to $TARGET failed (permissions or I/O). Nothing committed."
  exit 74
fi
fsync_file "$TARGET"

printf 'APPENDED key=%s fp=%s target=%s durability=%s\n' "$KEY" "$FP" "$TARGET" "$FSYNC_MECHANISM"
exit 0

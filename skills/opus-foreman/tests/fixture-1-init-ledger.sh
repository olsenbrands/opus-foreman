#!/bin/sh
# Fixture 1 (contract "Fixtures before acceptance" item 1) — init-ledger.sh.
#
#   * a fresh directory gets a ledger carrying the new ledger-v2 sections
#     (## Current, ## Reservations, ## Crew record) and a BASELINE line with
#     run=, host= and schema=ledger-v2;
#   * a second invocation exits 0, prints EXISTS, and leaves the file
#     byte-identical (sha256 compared, not eyeballed);
#   * a directory that is not a git repository still works.
#
# Hermetic: everything happens under one mktemp -d, removed on exit. Nothing is
# read from or written to $HOME.
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/lib.sh"
SCRIPT="$HERE/../scripts/init-ledger.sh"

TMP=$(mktemp -d "${TMPDIR:-/tmp}/foreman-fx1.XXXXXX") || exit 1
trap 'rm -rf "$TMP"' EXIT INT TERM

# ---------------------------------------------------------------- case 1.1
# Fresh, non-git directory.
mkdir -p "$TMP/nogit"
OUT=$( cd "$TMP/nogit" && sh "$SCRIPT" "fixture one run" ".foreman" 2>&1 ); RC=$?
LEDGER="$TMP/nogit/.foreman/ledger.md"

assert_eq "1.1 fresh dir: exit 0" "0" "$RC"
case "$OUT" in *CREATED:*) pass "1.1 fresh dir: prints CREATED" ;; *) fail "1.1 fresh dir: prints CREATED (got: $OUT)" ;; esac
assert_file "1.1 fresh dir: ledger created" "$LEDGER"
assert_contains "1.1 ledger has ## Current"      "$LEDGER" "## Current"
assert_contains "1.1 ledger has ## Reservations" "$LEDGER" "## Reservations"
assert_contains "1.1 ledger has ## Crew record"  "$LEDGER" "## Crew record"
assert_contains "1.1 Current has Missing gate placeholder"   "$LEDGER" "- Missing gate:"
assert_contains "1.1 Current has Held surfaces placeholder"  "$LEDGER" "- Held surfaces:"
assert_contains "1.1 Reservations name LAUNCH UNKNOWN"       "$LEDGER" "LAUNCH UNKNOWN"
assert_contains "1.1 Reservations state the line format"     "$LEDGER" "token | outcome id | write set | requested route | identity-after-launch"
assert_contains "1.1 Crew record names crew-append.sh"       "$LEDGER" "crew-append.sh"
assert_contains "1.1 Crew record has route hypothesis"       "$LEDGER" "Route hypothesis:"
assert_contains "1.1 ledger has ## Recovery" "$LEDGER" "## Recovery"
assert_contains "1.1 Recovery lists the reservation columns" "$LEDGER" "<outcome id | diagnosed cause | changed approach | bounded"
assert_contains "1.1 Recovery names its stopping observation" "$LEDGER" "stopping observation>"

# Run identity lives on its own RUN: line, in delegation.md's shape:
#   RUN: <run id> | host <hostname> | ledger schema <version>
if grep -Eq '^RUN: [0-9a-f]{8} \| host [^ ]+ \| ledger schema ledger-v2$' "$LEDGER"; then
  pass "1.1 RUN: line carries run id, host and ledger schema"
else
  fail "1.1 RUN: line carries run id, host and ledger schema (got: $(grep '^RUN:' "$LEDGER"))"
fi
if [ "$(grep -c '^RUN:' "$LEDGER")" = "1" ] && [ "$(sed -n '3p' "$LEDGER" | cut -c1-4)" = "RUN:" ]; then
  pass "1.1 RUN: appears exactly once, immediately after BASELINE"
else
  fail "1.1 RUN: appears exactly once, immediately after BASELINE"
fi
# delegation.md's BASELINE line is hash | dirty summary | date — run/host/schema
# belong to the RUN: line and must not be duplicated onto it.
if grep -Eq '^BASELINE: .* \| [0-9]+ dirty files \| [0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]+Z$' "$LEDGER"; then
  pass "1.1 BASELINE keeps the schema's three fields"
else
  fail "1.1 BASELINE keeps the schema's three fields (got: $(grep '^BASELINE:' "$LEDGER"))"
fi
assert_contains "1.1 non-git baseline recorded as such" "$LEDGER" "no git repository"

# ---------------------------------------------------------------- case 1.5
# The ledger's section ORDER must match the schema block in delegation.md. Both
# lists are extracted at test time, so the two drifting apart fails here rather
# than being discovered in a live run.
DELEGATION="$HERE/../references/delegation.md"
if [ -f "$DELEGATION" ]; then
  awk '/^## Ledger schema/{f=1} f && /^```/{c++} f && c==1 && /^## /{print}' "$DELEGATION" \
    | sed -E 's/^## ([A-Za-z]+( [A-Za-z]+)*).*/\1/' > "$TMP/schema-order"
  grep '^## ' "$LEDGER" | sed -E 's/^## ([A-Za-z]+( [A-Za-z]+)*).*/\1/' > "$TMP/ledger-order"
  if [ -s "$TMP/schema-order" ]; then
    pass "1.5 delegation.md schema block found and parsed"
    if diff -u "$TMP/schema-order" "$TMP/ledger-order" > "$TMP/order.diff" 2>&1; then
      pass "1.5 ledger section order matches delegation.md exactly ($(wc -l < "$TMP/schema-order" | tr -d ' ') sections)"
    else
      fail "1.5 ledger section order matches delegation.md exactly"
      sed -n '1,40p' "$TMP/order.diff"
    fi
  else
    fail "1.5 delegation.md schema block found and parsed (no headings extracted)"
  fi
else
  fail "1.5 delegation.md present to compare section order against"
fi

# ---------------------------------------------------------------- case 1.2
# Second invocation: exit 0, EXISTS, byte-identical.
BEFORE=$(sha_of "$LEDGER")
OUT2=$( cd "$TMP/nogit" && sh "$SCRIPT" "a different title" ".foreman" 2>&1 ); RC2=$?
AFTER=$(sha_of "$LEDGER")
assert_eq "1.2 existing ledger: exit 0"        "0" "$RC2"
case "$OUT2" in *EXISTS:*) pass "1.2 existing ledger: prints EXISTS" ;; *) fail "1.2 existing ledger: prints EXISTS (got: $OUT2)" ;; esac
assert_eq "1.2 existing ledger: byte-identical" "$BEFORE" "$AFTER"

# ---------------------------------------------------------------- case 1.3
# A real git repository: baseline recorded, gitignore note emitted when the
# ledger directory is not ignored.
mkdir -p "$TMP/repo"
( cd "$TMP/repo" && git init -q . && git config user.email t@example.invalid && git config user.name t ) >/dev/null 2>&1
OUT3=$( cd "$TMP/repo" && sh "$SCRIPT" "git run" ".foreman" 2>&1 ); RC3=$?
LEDGER3="$TMP/repo/.foreman/ledger.md"
assert_eq "1.3 git repo: exit 0" "0" "$RC3"
assert_file "1.3 git repo: ledger created" "$LEDGER3"
assert_contains "1.3 git repo: unborn HEAD recorded" "$LEDGER3" "unborn (no commits yet)"
assert_contains "1.3 git repo: has ## Current" "$LEDGER3" "## Current"
case "$OUT3" in *"is not gitignored"*) pass "1.3 git repo: gitignore note preserved" ;; *) fail "1.3 git repo: gitignore note preserved (got: $OUT3)" ;; esac

# ---------------------------------------------------------------- case 1.4
# The scratch directory the ledger points at is really created.
if [ -d "$TMP/nogit/.foreman/scratch" ]; then pass "1.4 scratch dir created"; else fail "1.4 scratch dir created"; fi

finish "fixture 1 (init-ledger)"

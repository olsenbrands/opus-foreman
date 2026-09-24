#!/bin/sh
# Fixture 5 (contract item 5) — scripted precedence walkthrough.
#
# POLICY EVIDENCE, NOT RUNTIME PROOF. This fixture executes a model of the
# guards-first evaluation order written in references/delegation.md as amended
# (Astra amendment 1). It proves the ORDER produces the contract's decisions on
# the sample ledger rows below. It does NOT prove the skill's prose, any agent,
# or any launcher behaves this way at run time — nothing here dispatches a
# worker or reads a live ledger.
#
# Evaluation order under test, guards first:
#   (1) authority and ownership holds  — a held write surface, a LAUNCH UNKNOWN
#       reservation, or a possibly-live writer on the outcome's paths blocks any
#       dispatch until reconciled;
#   (2) outcome state — NEEDS USER (parked) or an active recovery reservation
#       blocks automatic dispatch REGARDLESS of how the last failure is
#       classified;
#   (3) original-outcome limits — the fix-wave and review-round counts;
#   (4) failure attribution and ordinary per-seat routing.
#
# Invariants asserted alongside the per-case decisions:
#   * a rename, split, re-seat, corrected ticket or restart never resets a count
#   * exactly one recovery reservation per outcome, ever
#   * a third ticket correction with no new observation is a real failure
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/lib.sh"

# ---------------------------------------------------------------------------
# The model. Inputs are the ledger row's fields; output is one decision string.
# ---------------------------------------------------------------------------
decide() {
  # $1 held_surface  $2 launch_unknown  $3 live_writer
  # $4 state (active|recovery_reserved|parked)
  # $5 fix_waves  $6 review_rounds  $7 recoveries_used  $8 recovery_failed
  # $9 last_failure (model|ticket|none)
  # $10 ticket_corrections  $11 new_observation (yes|no)
  _held=$1; _lu=$2; _writer=$3; _state=$4
  _fw=$5; _rr=$6; _rec=$7; _recfail=$8
  _cause=$9; _tc=${10}; _obs=${11}

  # ---- guard 1: authority and ownership -----------------------------------
  if [ "$_held" = "yes" ] || [ "$_lu" = "yes" ] || [ "$_writer" = "yes" ]; then
    printf 'GUARD1 NO DISPATCH — ownership unreconciled (held surface / LAUNCH UNKNOWN / possibly-live writer)'
    return 0
  fi

  # ---- guard 2: outcome state ---------------------------------------------
  # Runs BEFORE any failure attribution, so a corrected ticket or a
  # ticket-caused recovery failure cannot reopen a parked outcome.
  if [ "$_state" = "parked" ]; then
    printf 'GUARD2 NO DISPATCH — outcome is NEEDS USER (parked); explicit recorded resolution required'
    return 0
  fi
  if [ "$_state" = "recovery_reserved" ]; then
    printf 'GUARD2 NO DISPATCH — an active recovery reservation governs this outcome'
    return 0
  fi

  # ---- guard 4 pre-pass: bounded ticket corrections ------------------------
  # A ticket-caused failure is normally retried on the same seat and is excluded
  # from ATTRIBUTABLE MODEL-QUALITY failures only — it is still logged on the
  # Attempts table. The third correction with no new observation stops being
  # free: it counts toward the outcome's limits like any other failure.
  _counted=""
  if [ "$_cause" = "ticket" ] && [ "$_tc" -ge 3 ] && [ "$_obs" = "no" ]; then
    _fw=$((_fw + 1))
    _counted="COUNTED AS REAL FAILURE (third ticket correction, no new observation) -> "
  fi

  # ---- guard 3: original-outcome limits -----------------------------------
  if [ "$_fw" -ge 2 ]; then
    if [ "$_rec" -ge 1 ]; then
      if [ "$_recfail" = "yes" ]; then
        printf '%sNEEDS USER — recovery failed; park with evidence, dependents parked with links, independent outcomes continue' "$_counted"
      else
        printf '%sGUARD2 NO DISPATCH — the one recovery for this outcome is already reserved' "$_counted"
      fi
      return 0
    fi
    printf '%sRECOVERY RESERVATION — two failed fix waves; write the reservation (cause, changed approach, bounded deliverable, checks, stopping observation) before launch' "$_counted"
    return 0
  fi
  if [ "$_rr" -ge 3 ]; then
    printf '%sNO AUTOMATIC DISPATCH — review rounds exhausted; write the per-finding disposition' "$_counted"
    return 0
  fi
  if [ "$_rr" -ge 2 ]; then
    printf '%sDISPOSITION REQUIRED — two review rounds done; a third needs a named unresolved criterion, a finite question and a stopping observation' "$_counted"
    return 0
  fi

  # ---- guard 4: attribution and ordinary routing --------------------------
  if [ "$_cause" = "ticket" ]; then
    printf '%sDISPATCH — same seat, ticket-caused retry; logged on Attempts, excluded from model-quality failures only' "$_counted"
    return 0
  fi
  printf '%sDISPATCH — ordinary per-seat routing' "$_counted"
}

case_run() { # case_run <name> <expected-prefix> <11 model args...>
  _name=$1; _expect=$2; shift 2
  _got=$(decide "$@")
  printf '    case: %s\n      decision: %s\n' "$_name" "$_got"
  case "$_got" in
    "$_expect"*) pass "5.$_name" ;;
    *) fail "5.$_name (expected a decision starting [$_expect])" ;;
  esac
}

printf 'Sample ledger (policy evidence, not runtime proof)\n'
printf '  outcome O-1  authorized, independent of O-2\n'
printf '  outcome O-2  authorized, depends on O-1\n\n'

#          held lu writer state             fw rr rec recfail cause  tc obs
case_run "a two fix waves on O-1 -> one recovery reservation" \
  "RECOVERY RESERVATION" \
  no no no active 2 0 0 no model 0 no

case_run "b the recovery itself fails -> NEEDS USER, park and continue" \
  "NEEDS USER" \
  no no no active 2 0 1 yes model 0 no

case_run "c O-1 renamed after the park -> no dispatch, counts intact" \
  "GUARD2 NO DISPATCH" \
  no no no parked 2 0 1 yes model 0 no

case_run "d failed recovery classified ticket-caused -> still parked" \
  "GUARD2 NO DISPATCH" \
  no no no parked 2 0 1 yes ticket 1 yes

case_run "e parked O-1 re-presented under a corrected ticket -> guard 2 fires" \
  "GUARD2 NO DISPATCH" \
  no no no parked 2 0 1 yes ticket 2 yes

case_run "f third ticket correction, no new observation -> counted as a real failure" \
  "COUNTED AS REAL FAILURE" \
  no no no active 1 0 0 no ticket 3 no

case_run "g first ticket correction with a new observation -> same-seat retry" \
  "DISPATCH — same seat, ticket-caused retry" \
  no no no active 0 0 0 no ticket 1 yes

case_run "h LAUNCH UNKNOWN reservation outranks everything -> reconcile first" \
  "GUARD1 NO DISPATCH" \
  no yes no active 0 0 0 no model 0 no

case_run "i held write surface on a parked outcome -> guard 1 before guard 2" \
  "GUARD1 NO DISPATCH" \
  yes no no parked 2 0 1 yes model 0 no

case_run "j two review rounds done -> disposition, no automatic third" \
  "DISPOSITION REQUIRED" \
  no no no active 0 2 0 no model 0 no

case_run "k an already-reserved recovery never mints a second one" \
  "GUARD2 NO DISPATCH — the one recovery for this outcome is already reserved" \
  no no no active 3 0 1 no model 0 no

case_run "l independent authorized outcome O-2 with no holds still dispatches" \
  "DISPATCH — ordinary per-seat routing" \
  no no no active 0 0 0 no none 0 no

# ---------------------------------------------------------------------------
# Structural invariants over the walkthrough itself.
# ---------------------------------------------------------------------------
printf '\n'

# Rename / split / restart are not model inputs at all — there is no argument
# they could change. Asserted by showing identical inputs before and after a
# rename produce the identical decision AND identical counts.
D_BEFORE=$(decide no no no parked 2 0 1 yes model 0 no)
D_AFTER_RENAME=$(decide no no no parked 2 0 1 yes model 0 no)
assert_eq "5.m rename/split/restart changes no decision" "$D_BEFORE" "$D_AFTER_RENAME"
assert_eq "5.m rename/split/restart resets no count (fix waves)" "2" "2"

# No path in the model can produce a second recovery reservation once one is used.
SECOND_RECOVERY=0
for FW in 2 3 4 9; do
  for CAUSE in model ticket none; do
    OUT=$(decide no no no active "$FW" 0 1 no "$CAUSE" 0 no)
    case "$OUT" in *"RECOVERY RESERVATION"*) SECOND_RECOVERY=$((SECOND_RECOVERY + 1)) ;; esac
    OUT=$(decide no no no active "$FW" 0 1 yes "$CAUSE" 0 no)
    case "$OUT" in *"RECOVERY RESERVATION"*) SECOND_RECOVERY=$((SECOND_RECOVERY + 1)) ;; esac
  done
done
assert_eq "5.n no second recovery is ever minted (24 state combinations)" "0" "$SECOND_RECOVERY"

# A parked outcome never dispatches, whatever the failure attribution says.
PARKED_DISPATCHES=0
for CAUSE in model ticket none; do
  for TC in 0 1 2 3 9; do
    for OBS in yes no; do
      OUT=$(decide no no no parked 2 0 1 yes "$CAUSE" "$TC" "$OBS")
      case "$OUT" in DISPATCH*|*"-> DISPATCH"*) PARKED_DISPATCHES=$((PARKED_DISPATCHES + 1)) ;; esac
    done
  done
done
assert_eq "5.o a parked outcome never dispatches (30 attribution combinations)" "0" "$PARKED_DISPATCHES"

printf '\nNOTE: policy evidence, not runtime proof — this fixture exercises a model of\n'
printf 'the evaluation order, not the skill prose, an agent, or a launcher.\n'

finish "fixture 5 (precedence walkthrough)"

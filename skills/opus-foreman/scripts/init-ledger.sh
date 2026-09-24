#!/bin/sh
# opus-foreman — ledger bootstrap.
# Usage: init-ledger.sh "<task title>" [ledger-dir]
# Idempotent: refuses to overwrite an existing ledger (resume runs must
# reconcile, not reset — delegation.md). Fails loudly and nonzero on any error;
# creation is atomic (noclobber) so concurrent invocations cannot clobber.
set -eu

RAW_TITLE="${1:-untitled run}"
DIR="${2:-.foreman}"
LEDGER="$DIR/ledger.md"

# Strip control characters (incl. newlines) so a title cannot forge ledger
# sections that get trusted after compaction.
TITLE=$(printf '%s' "$RAW_TITLE" | tr -d '\000-\037\177')

if [ -f "$LEDGER" ]; then
  echo "EXISTS: $LEDGER — reconcile against the tree before dispatching (delegation.md). Not overwriting."
  exit 0
fi

mkdir -p "$DIR/scratch"

if git rev-parse --git-dir >/dev/null 2>&1; then
  HASH=$(git rev-parse -q --verify HEAD 2>/dev/null) || HASH=""
  [ -n "$HASH" ] || HASH="unborn (no commits yet)"
  STATUS=$(git status --porcelain)   # set -e aborts here if git fails
  DIRTY=$(printf '%s' "$STATUS" | grep -c . || true)
else
  HASH="no git repository"
  STATUS=""
  DIRTY=0
fi

# Run identity. RUN_ID is the stable key every crew record and every global
# append is keyed on (with host and outcome id); it must not be derived from
# the title or the path, or two runs on one task would collide.
if [ -r /dev/urandom ]; then
  RUN_ID=$(od -An -tx1 -N4 /dev/urandom | tr -d ' \n')
else
  RUN_ID=""
fi
[ -n "$RUN_ID" ] || RUN_ID=$(printf '%08x' "$$")
RUN_HOST=$(hostname 2>/dev/null) || RUN_HOST=$(uname -n)
[ -n "$RUN_HOST" ] || RUN_HOST="unknown-host"
SCHEMA=ledger-v2

TMP=$(mktemp "$DIR/.ledger-tmp.XXXXXX")
{
  printf '# Foreman Ledger — %s\n' "$TITLE"
  printf 'BASELINE: %s | %s dirty files | %s\n' "$HASH" "$DIRTY" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  # Run identity lives on its own RUN: line, in the shape delegation.md's ledger
  # schema block specifies. The schema's BASELINE line carries hash, dirty
  # summary and date only, so run/host/schema are NOT duplicated onto it.
  printf 'RUN: %s | host %s | ledger schema %s\n' "$RUN_ID" "$RUN_HOST" "$SCHEMA"
  printf '\n### Baseline worktree state (git status --porcelain, verbatim)\n```\n%s\n```\n' "$STATUS"

  # Section order below is the schema block in references/delegation.md,
  # verbatim and in order. tests/fixture-1 re-reads that block and fails if the
  # two ever drift apart.

  # The only overwritten section — the live picture, and the first thing read
  # back after a compaction. Placeholders are replaced, never appended to.
  printf '\n## Current\n'
  printf -- '- Outcome: <outcome id — the unit all four counts are keyed on>\n'
  printf -- '- State: <planned | dispatched | in review | recovery | NEEDS USER (parked) | accepted>\n'
  printf -- '- Owner: <who holds the write surface right now>\n'
  printf -- '- Active workers: <in-flight dispatches: seat + identity + pid/job/session id, or none>\n'
  printf -- '- Next action: <the single next dispatch or check>\n'
  printf -- '- Missing gate: <the criterion still unmet, or none>\n'
  printf -- '- Parked: <outcome id -> question -> resume condition, or none>\n'
  printf -- '- Held surfaces: <paths held because a writer may be live, incl. LAUNCH UNKNOWN rows, or none>\n'

  printf '\n## Plan\n<numbered outcomes, outcome id + class per outcome>\n'
  printf '\n## Routing\n<outcome -> class -> seat (+effort requested / applied) — why;\n route hypothesis + what would overturn it; one line each>\n'
  printf '\n## Tasks\n<outcome id | lifecycle state | owned paths | job id | depends-on>\n'

  # Written BEFORE launch, so a launch whose result is unknown stays reconcilable.
  printf '\n## Reservations\n'
  printf -- '<one line WRITTEN BEFORE each dispatch:\n'
  printf -- '  token | outcome id | write set | requested route | identity-after-launch\n'
  printf -- ' i.e. outcome id | seat | intended write surface | expected runtime |\n'
  printf -- ' reservation id; the launched identity (pid / job id / session id) is\n'
  printf -- ' APPENDED after launch. A row with no identity reads LAUNCH UNKNOWN: the\n'
  printf -- ' surface stays held and is reconciled against live processes before any\n'
  printf -- ' re-dispatch touching it (precedence guard 1).>\n'

  # Exactly one recovery per outcome, reserved before launch. A failed recovery
  # parks the outcome at NEEDS USER; it never mints a second recovery.
  printf '\n## Recovery\n'
  printf -- '<outcome id | diagnosed cause | changed approach | bounded\n'
  printf -- ' deliverable | checks + executor | stopping observation>\n'

  printf '\n## Attempts\n'
  printf -- '<append-only, one line per attempt:\n'
  printf -- ' outcome id | attempt # | delivery/fix-wave/review-round/recovery\n'
  printf -- ' counts | seat + effort | seat-evidence tier | ticket rev |\n'
  printf -- ' outcome (status/verdict/LOST + failure class) |\n'
  printf -- ' checks run + executor + results | evidence/artifact paths |\n'
  printf -- ' timestamp>\n'

  # Fields the surface does not expose are recorded as `unavailable` — an absent
  # measurement is never rendered as a zero.
  printf '\n## Crew record\n'
  printf -- '<one row per dispatch: outcome id | role | task shape | risk |\n'
  printf -- ' requested model + requested effort | effort applied |\n'
  printf -- ' seat-evidence tier | cost estimate | evidenced charge | quota |\n'
  printf -- ' elapsed (execution and waiting separately) | disposition;\n'
  printf -- ' any field the surface does not expose is `unavailable`>\n'
  printf -- ' Route hypothesis: <route> because <reason>; keep-or-change: <decision>;\n'
  printf -- ' overturning observation: <what would change it>; proof: <links>.\n'
  printf -- ' At closure, append the run summary to the global performance record with\n'
  printf -- ' scripts/crew-append.sh (serialized, idempotent on host+run+outcome+rev;\n'
  printf -- ' corrections are new records with a higher rev, never rewrites).\n'

  printf '\n## Decisions\n<choices + why; Codex billing mode; seat changes; degradations; consent\n grants; dispositions after two review rounds>\n'
  printf '\n## Scratch\n%s/scratch/\n' "$DIR"
} > "$TMP"

# Atomic exclusive create via hard link: the full content is already safely in
# TMP (same directory, same filesystem), and link(2) either publishes it whole
# under the ledger name or fails because the name exists — there is no partial-
# ledger state and no way to mistake our own failed write for a concurrent
# creation (the failure mode Codex round-3 finding 9 identified in the
# noclobber approach).
if ln "$TMP" "$LEDGER" 2>/dev/null; then
  rm -f "$TMP"
  echo "CREATED: $LEDGER (baseline: $HASH, $DIRTY dirty files, run=$RUN_ID host=$RUN_HOST schema=$SCHEMA)"
  # The ledger lives in the project being worked on. If it is not ignored there,
  # the verifier's clean-tree check can never pass (verification.md).
  if git rev-parse --git-dir >/dev/null 2>&1; then
    git check-ignore -q "$DIR" 2>/dev/null \
      || echo "NOTE: $DIR is not gitignored — add '$DIR/' to .gitignore or .git/info/exclude so the verifier's clean-tree check stays meaningful (delegation.md)"
  fi
elif [ -e "$LEDGER" ]; then
  rm -f "$TMP"
  echo "EXISTS (created concurrently): $LEDGER — reconcile, do not overwrite."
  exit 0
else
  rm -f "$TMP"
  echo "ERROR: could not create $LEDGER (link failed, file absent — permissions or I/O)" >&2
  exit 1
fi

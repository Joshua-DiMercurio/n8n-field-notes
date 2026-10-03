#!/bin/zsh
# Session preflight — speaks ONLY when something needs attention.
#
# Built against three failures that actually happened, not a generic checklist:
#   1. Weeks of commits sat unpushed because nothing measured sync.
#   2. A public page called a webhook whose workflow had been paused, so the
#      page was quietly broken for visitors while every dashboard looked fine.
#   3. A scheduled workflow failed 100% of runs for a month with no
#      errorWorkflow set, so it alerted nowhere.
#
# Design rules, each learned the expensive way:
#   - QUIET ON SUCCESS. Noise is what lets a real alert go unseen. A line you
#     learn to skip is worse than no line, because the real one prints in the
#     same block.
#   - NEVER BLOCK A SESSION: everything is timeout-bounded and fails soft.
#   - Absolute binary paths — PATH is not dependable in a hook shell.
#
# SETUP
#   export N8N_BASE="https://<your-instance>.app.n8n.cloud"
#   export PREFLIGHT_REPOS="repo-a repo-b"      # dirs under $PREFLIGHT_ROOT
#   export PREFLIGHT_ROOT="$HOME/code"          # default: $HOME
#   export PREFLIGHT_SITE_DIR="$HOME/code/site" # optional, enables check 2
#
# An ack file (one id or path per line, '#' for comments) silences known-and-
# accepted findings without weakening the check:
#   export PREFLIGHT_ACK="$HOME/.preflight-ack"

CURL=/usr/bin/curl; JQ=/usr/bin/jq; GIT=/usr/bin/git
ACK="${PREFLIGHT_ACK:-${0:A:h}/preflight-ack.txt}"
acked() { [[ -f "$ACK" ]] && /usr/bin/grep -v '^#' "$ACK" | /usr/bin/awk '{print $1}' \
            | /usr/bin/grep -qxF "$1" }
ROOT="${PREFLIGHT_ROOT:-$HOME}"; OUT=""
note() { OUT+="$1"$'\n' }

# ── 1. every repo: is the work actually anywhere but this laptop? ────────────
for r in ${=PREFLIGHT_REPOS}; do
  p="$ROOT/$r"; [[ -d "$p/.git" ]] || continue
  $GIT -C "$p" fetch --quiet origin 2>/dev/null
  counts=$($GIT -C "$p" rev-list --left-right --count origin/main...main 2>/dev/null) || continue
  behind=${counts%%	*}; ahead=${counts##*	}
  dirty=$($GIT -C "$p" status --porcelain 2>/dev/null | /usr/bin/wc -l | /usr/bin/tr -d ' ')
  (( ahead  > 0 )) && note "  ⚠ $r: $ahead commit(s) UNPUSHED — only on this laptop. git -C $p push origin main"
  (( behind > 0 )) && note "  · $r: $behind behind origin"
  (( dirty  > 0 )) && ! acked "$r" && note "  · $r: $dirty uncommitted file(s)"

  # A branch with no upstream is only EXPOSED if its commits are not already in
  # main. This check used to warn on "no upstream" alone, which printed several
  # merged-but-undeleted branches every single session — never actionable, and
  # pure noise. "No upstream" and "not backed up" are different claims; warn
  # only where BOTH hold.
  nou=""
  if $GIT -C "$p" rev-parse --verify --quiet main >/dev/null 2>&1; then
    while read -r br up; do
      [[ -z "$br" || -n "$up" ]] && continue                                     # has upstream: safe
      $GIT -C "$p" merge-base --is-ancestor "$br" main 2>/dev/null && continue   # already merged: safe
      nou+="$br "
    done < <($GIT -C "$p" for-each-ref --format='%(refname:short) %(upstream:short)' refs/heads/ 2>/dev/null)
  else
    nou=$($GIT -C "$p" for-each-ref --format='%(refname:short) %(upstream:short)' refs/heads/ 2>/dev/null \
          | /usr/bin/awk 'NF==1{print $1}' | /usr/bin/tr '\n' ' ')
  fi
  [[ -n "$nou" ]] && note "  ⚠ $r: UNMERGED branch(es) with no upstream — laptop-only work: $nou"
done

KEY=$(/bin/cat "${N8N_API_KEY_FILE:-$HOME/.n8n-api-key}" 2>/dev/null | /usr/bin/tr -d '\n')
API="${N8N_BASE%/}/api/v1"

# ── 2. every webhook the SITE calls must have an ACTIVE workflow listening ───
# Read-only on purpose: probing by POST would mint junk records and analytics
# events. This is the check that catches "the page is broken for visitors" —
# a state no workflow-level dashboard can show you, because both halves look
# healthy on their own.
if [[ -n "$KEY" && -n "$N8N_BASE" && -n "$PREFLIGHT_SITE_DIR" && -d "$PREFLIGHT_SITE_DIR" ]]; then
  wf=$($CURL -s --max-time 12 -H "X-N8N-API-KEY: $KEY" "$API/workflows?limit=250" 2>/dev/null)
  if [[ -n "$wf" ]]; then
    /usr/bin/grep -rhoE "/webhook/[A-Za-z0-9_/-]+" "$PREFLIGHT_SITE_DIR" 2>/dev/null \
      | /usr/bin/grep -viE "node_modules" | /usr/bin/sed 's|.*/webhook/||' | /usr/bin/sort -u \
    | while read -r path; do
        [[ -z "$path" ]] && continue
        live=$(printf '%s' "$wf" | $JQ -r --arg p "$path" \
          '[.data[] | select(.active==true) | select((.nodes//[])[]?
             | select(.type=="n8n-nodes-base.webhook") | .parameters.path==$p)] | length' 2>/dev/null)
        acked "$path" && continue
        [[ "$live" == "0" || -z "$live" ]] && \
          note "  ⚠ /$path is called by the site but NO ACTIVE workflow listens — that page is broken for visitors"
      done
  fi
fi

# ── 3. workflows failing repeatedly ─────────────────────────────────────────
# Loud ones drown every other alarm on a shared channel; silent ones hide.
if [[ -n "$KEY" && -n "$N8N_BASE" ]]; then
  ex=$($CURL -s --max-time 12 -H "X-N8N-API-KEY: $KEY" \
       "$API/executions?status=error&limit=200" 2>/dev/null)
  # ISO-string compare, never fromdateiso8601 — see tools/n8n for the full
  # story. n8n timestamps carry milliseconds, which jq cannot parse; the old
  # form silently matched NOTHING, so this check never fired once in two and a
  # half weeks despite three workflows failing weekly. The check written to
  # catch a silent failure was itself silently dead, and looked healthy.
  [[ -n "$ex" ]] && printf '%s' "$ex" | $JQ -r '
      ((now - 259200) | todate) as $cut
      | [ .data[]? | select((.startedAt // "") > $cut) | .workflowId ]
      | group_by(.) | map({id: .[0], n: length}) | map(select(.n >= 3))
      | .[] | "  ⚠ workflow \(.id): \(.n) failures in the last 72h — check it"' 2>/dev/null \
    | while read -r l; do id=${l##*workflow }; id=${id%%:*}; acked "$id" || note "$l"; done
fi

# ── speak only if there is something to say ─────────────────────────────────
if [[ -n "$OUT" ]]; then
  print -r -- "── preflight ──"
  printf "%s" "$OUT"
  print -r -- "── (silence here means all clear) ──"
fi
exit 0

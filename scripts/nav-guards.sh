#!/usr/bin/env bash
#
# nav-guards.sh — allowlist-based navigation invariants guard.
#
# Each rule greps for a banned pattern across winston/ and FAILS if any match
# appears outside its allowlist. Rules are *phase-gated*: a rule only enforces
# once the navigation rebuild has reached the phase that makes it true, so this
# script stays green from day one and tightens as phases land (see the plan,
# docs/navigation-rebuild-plan.md). Without per-rule allowlists + phase gates
# these guards get noisy and ignored.
#
# Usage:
#   scripts/nav-guards.sh            # uses NAV_GUARD_PHASE (default 0)
#   NAV_GUARD_PHASE=2 scripts/nav-guards.sh
#
# Set NAV_GUARD_PHASE to the highest navigation-rebuild phase already COMPLETED.
# CI should bump it as each phase merges; the final state is NAV_GUARD_PHASE=5.
#
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/winston"
# The navigation rebuild is complete, so all rules enforce by default. Override with
# NAV_GUARD_PHASE=<n> only when intentionally working below the final state.
PHASE="${NAV_GUARD_PHASE:-5}"
status=0

# check <min_phase> <description> <regex> [allowed-path-substr...]
#   - min_phase : rule is skipped (reported "pending") until PHASE >= min_phase
#   - regex     : extended-regex banned pattern (grep -E)
#   - allowed   : path substrings exempt from the ban (the destination-host file,
#                 plus any intentionally-transitional files)
check() {
  local min_phase="$1"; shift
  local desc="$1"; shift
  local pattern="$1"; shift
  local allow=("$@")

  if [ "$PHASE" -lt "$min_phase" ]; then
    printf '  · pending (enforced at phase %s): %s\n' "$min_phase" "$desc"
    return 0
  fi

  local matches
  matches="$(grep -rnE --include='*.swift' -- "$pattern" "$SRC" 2>/dev/null || true)"

  local offenders=""
  if [ -n "$matches" ]; then
    while IFS= read -r line; do
      [ -z "$line" ] && continue
      local file="${line%%:*}"
      local rel="${file#"$ROOT"/}"
      local ok=0
      if [ "${#allow[@]}" -gt 0 ]; then
        for a in "${allow[@]}"; do
          case "$rel" in *"$a"*) ok=1; break;; esac
        done
      fi
      [ "$ok" -eq 0 ] && offenders+="$line"$'\n'
    done <<< "$matches"
  fi

  if [ -n "$offenders" ]; then
    printf '  ✗ FAILED: %s\n' "$desc"
    printf '      pattern: %s\n' "$pattern"
    printf '%s' "$offenders" | sed 's/^/      /'
    status=1
  else
    printf '  ✓ %s\n' "$desc"
  fi
}

echo "nav-guards (NAV_GUARD_PHASE=$PHASE)"

# Rule A — all Reddit stack destinations go through the centralized host.
# Allowed: the destination-host file. RedditForwardNavigationGesture (dead code)
# still references it until it is deleted in Phase 5 — trim it then.
check 1 "RouterDestinationView only in the destination host" \
  'RouterDestinationView' \
  'winston/Navigation/RedditDestinations.swift' \
  'winston/Navigation/RedditForwardNavigationGesture.swift'

# Rule B — no surface renders the legacy Router path directly.
check 4 "no NavigationStack(path: \$router.fullPath) rendering" \
  'NavigationStack\(path: \$router\.(fullPath|path)\)'

# Rule C — the hand-rolled forward-edge swipe is gone.
check 3 "no .forwardEdgeSwipe usage" \
  '\.forwardEdgeSwipe'

# Rule D — "Navigate from anywhere" is fully removed (flag + threaded params).
check 3 "no enableSwipeAnywhere / swipeAnywhere references" \
  'enableSwipeAnywhere|swipeAnywhere'

# Rule E — no live private-API navigation gesture attachment.
check 5 "no ViewControllerHolder / addFullSwipeGesture wiring" \
  'ViewControllerHolder|addFullSwipeGesture'

# Rule F — the legacy split model has no callers.
check 5 "no RedditSplitNavigationModel references" \
  'RedditSplitNavigationModel'

echo
if [ "$status" -ne 0 ]; then
  echo "nav-guards: FAILED"
else
  echo "nav-guards: OK"
fi
exit "$status"

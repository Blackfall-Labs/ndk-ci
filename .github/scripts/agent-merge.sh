#!/usr/bin/env bash
# Merge every ready pull request whose checks are all green.
#
# The rule, in one line: a pull request from a branch in this repository that
# is NOT a draft, carries no `hold` label, has no merge conflict, and whose
# required workflows all passed on its head commit is squash-merged.
#
#   draft            -> still being worked on; never merged
#   ready for review -> "done"; merged the moment CI is green
#   label `hold`     -> stop; nothing merges until the label comes off
#
# A merge made with GITHUB_TOKEN does not fire `push` workflows (GitHub's guard
# against recursive runs), so after merging, the workflows listed in
# POST_MERGE are dispatched on the base branch by hand. workflow_dispatch is
# the documented exception that GITHUB_TOKEN may trigger.
#
# Environment:
#   GH_TOKEN            token with contents:write, pull-requests:write, actions:write
#   GH_REPO             owner/name
#   REQUIRED_WORKFLOWS  workflow names, separated by "|", that must have passed
#   POST_MERGE          lines of "workflow-file base-branch path-regex"; the
#                       workflow is dispatched when the merge landed on that
#                       base and a changed file matches the regex ("." = any)
#   PR                  optional single PR number; otherwise every open PR
set -euo pipefail

: "${GH_REPO:?}" "${REQUIRED_WORKFLOWS:?}"
POST_MERGE="${POST_MERGE:-}"

log() { printf '%s\n' "$*"; }
summary() { [ -n "${GITHUB_STEP_SUMMARY:-}" ] && printf '%s\n' "$*" >> "$GITHUB_STEP_SUMMARY" || true; }

evaluate() {
  local pr="$1" info
  info=$(gh pr view "$pr" --repo "$GH_REPO" \
    --json number,state,isDraft,isCrossRepository,headRefName,headRefOid,baseRefName,mergeable,labels) || return 1

  local state draft cross head sha base mergeable hold
  state=$(jq -r .state <<<"$info")
  draft=$(jq -r .isDraft <<<"$info")
  cross=$(jq -r .isCrossRepository <<<"$info")
  head=$(jq -r .headRefName <<<"$info")
  sha=$(jq -r .headRefOid <<<"$info")
  base=$(jq -r .baseRefName <<<"$info")
  mergeable=$(jq -r .mergeable <<<"$info")
  hold=$(jq -r '[.labels[].name] | index("hold") != null' <<<"$info")

  [ "$state" = OPEN ]      || { log "#$pr: not open"; return 0; }
  [ "$cross" = false ]     || { log "#$pr: from a fork, never merged here"; return 0; }
  [ "$draft" = false ]     || { log "#$pr: draft, still being worked on"; return 0; }
  [ "$hold" = false ]      || { log "#$pr: held"; return 0; }
  [ "$mergeable" != CONFLICTING ] || { log "#$pr: conflicts with $base; the author rebases"; return 0; }

  # Every required workflow has a completed, successful run on the head commit.
  # Only the newest run of each name counts, so a re-run that went green wins.
  local runs name verdict
  runs=$(gh api "repos/$GH_REPO/actions/runs?head_sha=$sha&per_page=100" \
    --jq '.workflow_runs | sort_by(.created_at) | reverse | .[] | [.name, .status, (.conclusion // "")] | @tsv') || return 1
  IFS='|' read -r -a names <<<"$REQUIRED_WORKFLOWS"
  for name in "${names[@]}"; do
    verdict=$(awk -F'\t' -v n="$name" '$1 == n { print $2 "/" $3; exit }' <<<"$runs")
    case "$verdict" in
      completed/success) ;;
      "") log "#$pr: '$name' has not run on $sha yet"; return 0 ;;
      completed/*) log "#$pr: '$name' is $verdict on $sha; the author fixes it"; return 0 ;;
      *) log "#$pr: '$name' is still $verdict"; return 0 ;;
    esac
  done

  # Nothing else attached to the commit (another app's check) may be red or
  # pending. This job's own check run (job id `agent-merge`) is left out: on a
  # pull_request event it sits on the same commit, still in progress.
  local bad
  bad=$(gh api "repos/$GH_REPO/commits/$sha/check-runs?per_page=100" --paginate \
    --jq '.check_runs[] | select(.name != "agent-merge") | select(.status != "completed" or (.conclusion | IN("success","skipped","neutral") | not)) | .name') || return 1
  if [ -n "$bad" ]; then
    log "#$pr: checks not green: $(tr '\n' ',' <<<"$bad")"
    return 0
  fi

  log "#$pr: green on $sha, merging into $base"
  # --match-head-commit refuses the merge if anything was pushed since the check.
  gh pr merge "$pr" --repo "$GH_REPO" --squash --match-head-commit "$sha" \
    || { log "#$pr: GitHub refused the merge"; return 1; }
  summary "- merged #$pr ($head -> $base) at ${sha:0:7}"

  [ -n "$POST_MERGE" ] || return 0
  local files wf want_base pattern
  files=$(gh pr view "$pr" --repo "$GH_REPO" --json files --jq '.files[].path') || return 1
  while read -r wf want_base pattern; do
    [ -n "$wf" ] || continue
    [ "$base" = "$want_base" ] || continue
    if grep -Eq -- "$pattern" <<<"$files"; then
      log "#$pr: dispatching $wf on $base"
      gh workflow run "$wf" --repo "$GH_REPO" --ref "$base" || { log "#$pr: could not dispatch $wf"; return 1; }
      summary "  - dispatched $wf on $base"
    fi
  done <<<"$POST_MERGE"
}

if [ -n "${PR:-}" ]; then
  prs="$PR"
else
  prs=$(gh pr list --repo "$GH_REPO" --state open --limit 100 --json number --jq '.[].number')
fi

for pr in $prs; do
  evaluate "$pr" || { log "#$pr: evaluation failed"; failed=1; }
done
exit "${failed:-0}"

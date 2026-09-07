#!/usr/bin/env bash
# One tracking issue per channel for build failures.
#
#   issue.sh open  CHANNEL "message"   create or comment on the open issue
#   issue.sh close CHANNEL "message"   comment and close it, if one is open
#
# The issue is found by label `kestrel-failure` plus `channel:<name>`, so the
# title can change without losing track.

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
need gh jq

action=${1:?}
channel=${2:?}
message=${3:-}
repo=${GITHUB_REPOSITORY:-mheci/kestrel}
labels="kestrel-failure,channel:$channel"

ensure_labels() {
  gh label create kestrel-failure --repo "$repo" --color B60205 --description "A channel build is red" --force >/dev/null 2>&1 || true
  gh label create "channel:$channel" --repo "$repo" --color 0E8A16 --description "kestrel $channel channel" --force >/dev/null 2>&1 || true
}

find_open() {
  gh issue list --repo "$repo" --state open --label kestrel-failure --label "channel:$channel" --json number --jq '.[0].number // empty'
}

stamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
case "$action" in
  open)
    ensure_labels
    n=$(find_open)
    if [[ -n $n ]]; then
      gh issue comment "$n" --repo "$repo" --body "$stamp: $message"
      log "updated issue #$n"
    else
      n=$(gh issue create --repo "$repo" --title "kestrel $channel: build failing" --label "$labels" \
        --body "$stamp: $message

This issue is managed by the channel workflow. It is updated on every failed run and closed automatically when the channel publishes again." \
        | grep -oE '[0-9]+$')
      log "opened issue #$n"
    fi
    ;;
  close)
    n=$(find_open)
    if [[ -n $n ]]; then
      gh issue close "$n" --repo "$repo" --comment "$stamp: $message"
      log "closed issue #$n"
    else
      log "no open failure issue for $channel"
    fi
    ;;
  *) die "unknown action $action" ;;
esac

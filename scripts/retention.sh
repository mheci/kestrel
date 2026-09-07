#!/usr/bin/env bash
# Delete old kestrel package versions on ghcr.io.
#
#   retention.sh CHANNEL KEEP_PREVIOUS
#
# A "build" is one image digest with its set of tags. For the channel, the
# current build is whatever the floating tag points at; the KEEP_PREVIOUS
# newest other builds stay; older ones are deleted, along with the untagged
# cosign signature manifests that belonged to them. Builds of the other
# channel are never touched.

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
need gh jq

channel=${1:?}
keep=${2:?}
owner=${GITHUB_REPOSITORY_OWNER:-mheci}
pkg=kestrel

# All versions, newest first.
versions=$(gh api --paginate -H "Accept: application/vnd.github+json" \
  "users/$owner/packages/container/$pkg/versions?per_page=100" 2>/dev/null \
  || gh api --paginate "user/packages/container/$pkg/versions?per_page=100")
versions=$(jq -s 'add | sort_by(.created_at) | reverse' <<<"$versions")

current=$(jq -r --arg t "$channel" '.[] | select(.metadata.container.tags | index($t)) | .name' <<<"$versions" | head -1)
[[ -n $current ]] || die "no version carries the $channel tag"
log "current $channel: $current"

# Tagged builds of this channel other than current, newest first.
mapfile -t others < <(jq -r --arg ch "$channel" --arg cur "$current" '
  .[] | select(.name != $cur)
      | select((.metadata.container.tags | length) > 0)
      | select(any(.metadata.container.tags[]; startswith($ch + "-")))
      | "\(.id) \(.name) \(.metadata.container.tags | join(","))"' <<<"$versions")
log "${#others[@]} previous builds for $channel; keeping $keep"

deleted_digests=()
i=0
for line in "${others[@]}"; do
  i=$((i+1))
  id=${line%% *}; rest=${line#* }; digest=${rest%% *}; tags=${rest#* }
  if [[ $i -le $keep ]]; then log "keep   $digest ($tags)"; continue; fi
  log "delete $digest ($tags)"
  gh api -X DELETE "users/$owner/packages/container/$pkg/versions/$id" >/dev/null \
    || gh api -X DELETE "user/packages/container/$pkg/versions/$id" >/dev/null || log "delete failed for $id"
  deleted_digests+=("$digest")
done

# Cosign stores signatures as tags sha256-<digest>.sig; they show up as
# versions tagged that way. Remove the ones for deleted builds.
for d in "${deleted_digests[@]:-}"; do
  [[ -n $d ]] || continue
  sigtag="sha256-${d#sha256:}.sig"
  sid=$(jq -r --arg t "$sigtag" '.[] | select(.metadata.container.tags | index($t)) | .id' <<<"$versions" | head -1)
  if [[ -n $sid ]]; then
    gh api -X DELETE "users/$owner/packages/container/$pkg/versions/$sid" >/dev/null \
      || gh api -X DELETE "user/packages/container/$pkg/versions/$sid" >/dev/null || true
    log "deleted signature $sigtag"
  fi
done
log "retention done"

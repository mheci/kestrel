# shellcheck shell=bash
# Shared helpers for kestrel scripts. Source this file, do not execute it.

set -o errexit -o nounset -o pipefail

KESTREL_ROOT="${KESTREL_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
export KESTREL_ROOT

log() { printf '[%s] %s\n' "$(date -u +%H:%M:%S)" "$*" >&2; }
die() { printf '[%s] error: %s\n' "$(date -u +%H:%M:%S)" "$*" >&2; exit 1; }

# GitHub Actions log groups; plain lines outside Actions.
group() { if [[ -n ${GITHUB_ACTIONS:-} ]]; then printf '::group::%s\n' "$*"; else log "== $*"; fi; }
endgroup() { if [[ -n ${GITHUB_ACTIONS:-} ]]; then printf '::endgroup::\n'; fi; }

need() {
  local c
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || die "missing tool: $c"
  done
}

# gh_output NAME VALUE: set a step output when running under Actions.
gh_output() {
  if [[ -n ${GITHUB_OUTPUT:-} ]]; then
    printf '%s=%s\n' "$1" "$2" >>"$GITHUB_OUTPUT"
  fi
  log "output $1=$2"
}

# jget FILE FILTER: jq -r with a mandatory non-null result.
jget() {
  local v
  v=$(jq -r "$2" "$1")
  [[ -n $v && $v != null ]] || die "missing field $2 in $1"
  printf '%s' "$v"
}

# jget_opt FILE FILTER DEFAULT
jget_opt() {
  local v
  v=$(jq -r "$2 // empty" "$1")
  printf '%s' "${v:-$3}"
}

sha256_of() { sha256sum "$1" | cut -d' ' -f1; }

# curl with retries and a hard failure on HTTP errors.
fetch() {
  # fetch URL DEST
  curl --fail --location --silent --show-error --retry 5 --retry-delay 3 --retry-all-errors \
    --connect-timeout 20 --max-time 1800 -o "$2" "$1"
}

fetch_stdout() {
  curl --fail --location --silent --show-error --retry 5 --retry-delay 3 --retry-all-errors \
    --connect-timeout 20 --max-time 600 "$1"
}

# github_api PATH: authenticated when GITHUB_TOKEN/GH_TOKEN is set.
github_api() {
  local tok="${GH_TOKEN:-${GITHUB_TOKEN:-}}"
  if [[ -n $tok ]]; then
    curl --fail --silent --show-error --retry 3 --retry-delay 2 \
      -H "Authorization: Bearer $tok" -H "Accept: application/vnd.github+json" \
      -H "X-GitHub-Api-Version: 2022-11-28" "https://api.github.com/$1"
  else
    curl --fail --silent --show-error --retry 3 --retry-delay 2 \
      -H "Accept: application/vnd.github+json" "https://api.github.com/$1"
  fi
}

# Build tree hash: the parts of this repository that change the artifact.
kestrel_tree_hash() {
  (
    cd "$KESTREL_ROOT"
    # Sorted file list with content hashes, hashed again.
    find channels containers keys rpm scripts test .github/workflows/channel.yml .github/actions \
      -type f -print0 2>/dev/null | sort -z | xargs -0 sha256sum | sha256sum | cut -d' ' -f1
  )
}

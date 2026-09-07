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

# File lists for the three RPMs, from a staging root. Shared by package.sh and
# test/standin.sh so a stand-in has exactly the shape of a real build.
#   kestrel_file_lists STAGE KVER OUTDIR  -> OUTDIR/files.{core,devel,nvidia}
kestrel_file_lists() {
  local stage=$1 kver=$2 outdir=$3
  (
    cd "$stage" || exit 1
    find "usr/lib/modules/$kver" -mindepth 1 -maxdepth 1 ! -name extra ! -name build | sed 's|^|/|'
    echo "%dir /usr/lib/modules/$kver"
    echo "/usr/share/kestrel/LICENSES/GPL-2.0-only.kernel.txt"
    echo "/usr/share/kestrel/LICENSES/Apache-2.0.kestrel.txt"
    echo "/usr/share/kestrel/kestrel.crt"
    echo "%dir /usr/share/kestrel"
    echo "%dir /usr/share/kestrel/LICENSES"
    echo "/usr/share/doc/kestrel-kernel"
  ) >"$outdir/files.core"
  {
    echo "/usr/src/kernels/$kver"
    echo "/usr/lib/modules/$kver/build"
  } >"$outdir/files.devel"
  {
    echo "/usr/lib/modules/$kver/extra"
    echo "/usr/share/licenses/kestrel-nvidia-kmod"
    echo "/usr/share/kestrel/LICENSES/nvidia-open-gpu-kernel-modules.COPYING.txt"
  } >"$outdir/files.nvidia"
}

# rpmbuild the two specs from a staging root.
#   kestrel_rpmbuild STAGE KVER KVERSION KRELEASE NVVER NVRELEASE CHANNEL REL OUTDIR
# Leaves the RPMs in OUTDIR/rpms and logs in OUTDIR.
kestrel_rpmbuild() {
  local stage=$1 kver=$2 kversion=$3 krelease=$4 nvver=$5 nvrelease=$6 channel=$7 rel=$8 outdir=$9
  local top
  top=$(mktemp -d "${TMPDIR:-/tmp}/kestrel-rpm.XXXXXX")
  mkdir -p "$top"/{BUILD,RPMS,SPECS,SOURCES,SRPMS,BUILDROOT} "$outdir/rpms"
  kestrel_file_lists "$stage" "$kver" "$outdir"
  # RPM v4 package format: installable by rpm >= 4.14, so older Fedora bases work too.
  local common=(--define "_topdir $top" --define "_rpmformat 4" --define "kestrel_stage $stage"
                --define "kver $kver" --define "channel $channel" --define "dist .fc${rel}")
  rpmbuild -bb "${common[@]}" --define "kversion $kversion" --define "krelease $krelease" \
    --define "filelist_core $outdir/files.core" --define "filelist_devel $outdir/files.devel" \
    "$KESTREL_ROOT/rpm/kestrel-kernel.spec" >"$outdir/rpmbuild-kernel.log" 2>&1 \
    || { tail -40 "$outdir/rpmbuild-kernel.log" >&2; die "rpmbuild kernel failed"; }
  rpmbuild -bb "${common[@]}" --define "nvver $nvver" --define "nvrelease $nvrelease" \
    --define "filelist $outdir/files.nvidia" \
    "$KESTREL_ROOT/rpm/kestrel-nvidia-kmod.spec" >"$outdir/rpmbuild-nvidia.log" 2>&1 \
    || { tail -40 "$outdir/rpmbuild-nvidia.log" >&2; die "rpmbuild nvidia failed"; }
  find "$top/RPMS" -name '*.rpm' -exec mv -t "$outdir/rpms" {} +
  rm -rf "$top"
}

#!/usr/bin/env bash
# Resolve the inputs for one channel into a pinned "want" record.
#
# Reads:  channels/<channel>.env
# Writes: <out>/want.json  (everything a build needs, all pinned by hash)
#
# Inputs come from three upstreams:
#   1. CachyOS/linux-cachyos master, the PKGBUILD for the channel's variant
#      (pinned by the commit SHA that last touched that directory).
#   2. ghcr.io/ublue-os/kinoite-main:latest, whose version label gives the
#      Fedora release the artifact must be built for.
#   3. Terra's nvidia repository for that release, whose nvidia-driver
#      package version is the NVIDIA version the artifact must carry.

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
need curl jq python3 skopeo zstd sha256sum

channel=${1:?usage: resolve.sh CHANNEL OUTDIR}
out=${2:?usage: resolve.sh CHANNEL OUTDIR}
mkdir -p "$out"

# shellcheck source=/dev/null
source "$KESTREL_ROOT/channels/$channel.env"
[[ $KESTREL_CHANNEL == "$channel" ]] || die "channel file mismatch"

group "Pin CachyOS/linux-cachyos $KESTREL_VARIANT"
commits=$(github_api "repos/CachyOS/linux-cachyos/commits?path=$KESTREL_VARIANT&per_page=1")
pkgbuild_sha=$(jq -r '.[0].sha' <<<"$commits")
pkgbuild_date=$(jq -r '.[0].commit.committer.date' <<<"$commits")
[[ $pkgbuild_sha =~ ^[0-9a-f]{40}$ ]] || die "could not pin PKGBUILD commit"
raw="https://raw.githubusercontent.com/CachyOS/linux-cachyos/$pkgbuild_sha/$KESTREL_VARIANT"
fetch "$raw/PKGBUILD" "$out/PKGBUILD"
fetch "$raw/config" "$out/config.cachyos"
python3 "$KESTREL_ROOT/scripts/pkgbuild.py" "$out/PKGBUILD" >"$out/pkgbuild.json"
log "PKGBUILD $pkgbuild_sha ($pkgbuild_date): $(jq -r '.srctag' "$out/pkgbuild.json")"
endgroup

group "Fedora release from ghcr.io/ublue-os/kinoite-main:latest"
base_ref="ghcr.io/ublue-os/kinoite-main:latest"
skopeo inspect --retry-times 5 "docker://$base_ref" >"$out/base.json"
base_version=$(jq -r '.Labels["org.opencontainers.image.version"]' "$out/base.json")
base_digest=$(jq -r '.Digest' "$out/base.json")
fedora_release=${base_version%%.*}
[[ $fedora_release =~ ^[0-9]{2}$ ]] || die "unexpected base version label: $base_version"
log "base $base_ref version=$base_version release=$fedora_release digest=$base_digest"
endgroup

group "NVIDIA version from Terra terra${fedora_release}-nvidia"
terra="https://repos.fyralabs.com/terra${fedora_release}-nvidia"
fetch "$terra/repodata/repomd.xml" "$out/repomd.xml"
primary_href=$(python3 - "$out/repomd.xml" <<'EOF'
import sys, xml.etree.ElementTree as ET
ns = {"r": "http://linux.duke.edu/metadata/repo"}
root = ET.parse(sys.argv[1]).getroot()
for d in root.findall("r:data", ns):
    if d.get("type") == "primary":
        print(d.find("r:location", ns).get("href"))
EOF
)
[[ -n $primary_href ]] || die "no primary metadata in Terra repomd"
fetch "$terra/$primary_href" "$out/primary.bin"
case "$primary_href" in
  *.zst) zstd -dcq "$out/primary.bin" >"$out/primary.xml" ;;
  *.gz) gzip -dc "$out/primary.bin" >"$out/primary.xml" ;;
  *.xz) xz -dc "$out/primary.bin" >"$out/primary.xml" ;;
  *) cp "$out/primary.bin" "$out/primary.xml" ;;
esac
# Highest EVR wins when the repo carries more than one nvidia-driver build
# (dnf would pick the same one). The comparison is rpm's: split into digit
# and alpha runs, numeric runs compare as numbers, tilde sorts before
# anything, caret after everything except a longer string.
python3 - "$out/primary.xml" >"$out/terra.json" <<'EOF'
import json, re, sys, xml.etree.ElementTree as ET

def rpmvercmp(a, b):
    if a == b:
        return 0
    ia = ib = 0
    while ia < len(a) or ib < len(b):
        while ia < len(a) and not a[ia].isalnum() and a[ia] not in "~^":
            ia += 1
        while ib < len(b) and not b[ib].isalnum() and b[ib] not in "~^":
            ib += 1
        ta = a[ia] if ia < len(a) else ""
        tb = b[ib] if ib < len(b) else ""
        if ta == "~" or tb == "~":
            if ta != "~":
                return 1
            if tb != "~":
                return -1
            ia += 1; ib += 1
            continue
        if ta == "^" or tb == "^":
            if ia >= len(a):
                return -1
            if ib >= len(b):
                return 1
            if ta != "^":
                return 1
            if tb != "^":
                return -1
            ia += 1; ib += 1
            continue
        if ia >= len(a) or ib >= len(b):
            break
        pat = r"[0-9]+" if a[ia].isdigit() else r"[A-Za-z]+"
        ma = re.match(pat, a[ia:]); mb = re.match(pat, b[ib:])
        if mb is None:
            return 1 if a[ia].isdigit() else -1
        sa, sb = ma.group(0), mb.group(0)
        ia += len(sa); ib += len(sb)
        if a[ia - len(sa)].isdigit():
            sa, sb = sa.lstrip("0") or "0", sb.lstrip("0") or "0"
            if len(sa) != len(sb):
                return 1 if len(sa) > len(sb) else -1
        if sa != sb:
            return 1 if sa > sb else -1
    if ia >= len(a) and ib >= len(b):
        return 0
    return -1 if ia >= len(a) else 1

def evrcmp(x, y):
    for k in ("epoch", "version", "release"):
        c = rpmvercmp(x[k], y[k])
        if c:
            return c
    return 0

ns = {"c": "http://linux.duke.edu/metadata/common"}
root = ET.parse(sys.argv[1]).getroot()
found = None
for p in root.findall("c:package", ns):
    name = p.find("c:name", ns).text
    arch = p.find("c:arch", ns).text
    if name == "nvidia-driver" and arch == "x86_64":
        v = p.find("c:version", ns)
        cand = {"name": name, "epoch": v.get("epoch") or "0", "version": v.get("ver"), "release": v.get("rel"),
                "location": p.find("c:location", ns).get("href")}
        if found is None or evrcmp(cand, found) > 0:
            found = cand
if not found:
    sys.exit("nvidia-driver.x86_64 not found in Terra primary metadata")
json.dump(found, sys.stdout, indent=2)
EOF
nvidia_version=$(jget "$out/terra.json" .version)
[[ $nvidia_version =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]] || die "unexpected NVIDIA version: $nvidia_version"
log "Terra nvidia-driver $nvidia_version"
endgroup

group "NVIDIA kernel module source tarball"
nv_tarball="NVIDIA-kernel-module-source-${nvidia_version}.tar.xz"
nv_url="https://download.nvidia.com/XFree86/NVIDIA-kernel-module-source/${nv_tarball}"
# Only the headers; the build stage downloads the body.
curl --fail --silent --show-error --head --retry 3 "$nv_url" >/dev/null || die "NVIDIA source tarball not published: $nv_url"
endgroup

version=$(jget "$out/pkgbuild.json" .version)
tagrel=$(jget "$out/pkgbuild.json" .tagrel)
srctag=$(jget "$out/pkgbuild.json" .srctag)
major=$(jget "$out/pkgbuild.json" .major)
# uname -r in Fedora shape, VERSION-RELEASE.ARCH, so `rpm -q kestrel-kernel
# --qf '%{VERSION}-%{RELEASE}.%{ARCH}'` equals `uname -r` like it does for the
# Fedora kernel, and every kmod helper that builds kernel-uname-r from it works.
krelease="${tagrel}.${KESTREL_KVER_SUFFIX}.fc${fedora_release}"
kver="${version}-${krelease}.x86_64"
tree_hash=$(kestrel_tree_hash)

# build_id identifies the set of inputs. Same build_id, same artifact.
build_id=$(printf '%s\n' "$channel" "$srctag" "$pkgbuild_sha" "$nvidia_version" "$fedora_release" "$tree_hash" | sha256sum | cut -c1-16)

jq -n \
  --arg channel "$channel" \
  --arg variant "$KESTREL_VARIANT" \
  --arg kver "$kver" \
  --arg kernel_version "$version" \
  --arg kernel_major "$major" \
  --arg tagrel "$tagrel" \
  --arg krelease "$krelease" \
  --arg srctag "$srctag" \
  --arg source_url "https://github.com/CachyOS/linux/releases/download/${srctag}/${srctag}.tar.gz" \
  --arg pkgbuild_commit "$pkgbuild_sha" \
  --arg pkgbuild_date "$pkgbuild_date" \
  --arg pkgbuild_url "https://github.com/CachyOS/linux-cachyos/blob/$pkgbuild_sha/$KESTREL_VARIANT/PKGBUILD" \
  --arg config_sha256 "$(sha256_of "$out/config.cachyos")" \
  --arg patchsource "https://raw.githubusercontent.com/cachyos/kernel-patches/master/${major}" \
  --arg fedora_release "$fedora_release" \
  --arg base_ref "$base_ref" \
  --arg base_version "$base_version" \
  --arg base_digest "$base_digest" \
  --arg nvidia_version "$nvidia_version" \
  --arg nvidia_source_url "$nv_url" \
  --arg terra_repo "$terra" \
  --arg tree_hash "$tree_hash" \
  --arg build_id "$build_id" \
  --slurpfile pkgbuild "$out/pkgbuild.json" \
  --slurpfile terra "$out/terra.json" \
  '{
    channel: $channel, variant: $variant, kver: $kver, build_id: $build_id,
    kernel: {version: $kernel_version, major: $kernel_major, tagrel: $tagrel, rpm_release: $krelease, srctag: $srctag,
             source_url: $source_url, pkgbuild_commit: $pkgbuild_commit, pkgbuild_date: $pkgbuild_date,
             pkgbuild_url: $pkgbuild_url, config_sha256: $config_sha256, patchsource: $patchsource,
             knobs: $pkgbuild[0].knobs, kernel_patches: $pkgbuild[0].kernel_patches,
             nvidia_patches: $pkgbuild[0].nvidia_patches,
             cachyos_nvidia_version: $pkgbuild[0].cachyos_nvidia_version},
    fedora: {release: $fedora_release, base_ref: $base_ref, base_version: $base_version, base_digest: $base_digest},
    nvidia: {version: $nvidia_version, source_url: $nvidia_source_url, terra_repo: $terra_repo,
             terra_package: $terra[0]},
    kestrel: {tree_hash: $tree_hash}
  }' >"$out/want.json"

rm -f "$out/primary.bin" "$out/primary.xml" "$out/repomd.xml"
log "want: $(jq -c '{channel, kver, build_id, nvidia: .nvidia.version, fedora: .fedora.release}' "$out/want.json")"
gh_output kver "$kver"
gh_output build_id "$build_id"
gh_output nvidia_version "$nvidia_version"
gh_output fedora_release "$fedora_release"
gh_output srctag "$srctag"

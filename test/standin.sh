#!/usr/bin/env bash
# Build stand-in kestrel RPMs with no kernel inside: the real specs, the real
# file-list rules, the real names and provides, and a payload of placeholder
# files. Lets the consumer path (Terra transaction, kestrel-install's removal
# and guard logic) be exercised in minutes without a five hour compile.
#
#   standin.sh WANT_JSON OUT_DIR
#
# Nothing produced here is bootable or publishable; OUT_DIR/manifest.json
# says "standin": true so kestrel-install can refuse to run dracut on it.

source "$(dirname "${BASH_SOURCE[0]}")/../scripts/lib.sh"
need rpmbuild jq

want=$(readlink -f "${1:?usage: standin.sh WANT_JSON OUT_DIR}")
out=${2:?usage: standin.sh WANT_JSON OUT_DIR}
mkdir -p "$out"; out=$(readlink -f "$out")

kver=$(jget "$want" .kver)
kversion=$(jget "$want" .kernel.version)
krelease=$(jget "$want" .kernel.rpm_release)
tagrel=$(jget "$want" .kernel.tagrel)
channel=$(jget "$want" .channel)
nvver=$(jget "$want" .nvidia.version)
rel=$(jget "$want" .fedora.release)

stage=$(mktemp -d "${TMPDIR:-/tmp}/kestrel-standin.XXXXXX")
trap 'rm -rf "$stage"' EXIT
modlib="$stage/usr/lib/modules/$kver"
mkdir -p "$modlib/kernel/drivers/block" "$modlib/extra/nvidia" "$stage/usr/src/kernels/$kver/scripts/basic" \
  "$stage/usr/share/kestrel/LICENSES" "$stage/usr/share/licenses/kestrel-nvidia-kmod" "$stage/usr/share/doc/kestrel-kernel"
for f in vmlinuz System.map config modules.order modules.builtin modules.builtin.modinfo; do
  printf 'kestrel stand-in, not a real %s\n' "$f" >"$modlib/$f"
done
printf 'stand-in\n' >"$modlib/kernel/drivers/block/loop.ko.zst"
printf 'stand-in\n' >"$modlib/extra/nvidia/nvidia.ko.zst"
ln -sfn "/usr/src/kernels/$kver" "$modlib/build"
printf 'stand-in\n' >"$stage/usr/src/kernels/$kver/Module.symvers"
printf '#!/bin/sh\nexit 0\n' >"$stage/usr/src/kernels/$kver/scripts/basic/fixdep"; chmod +x "$stage/usr/src/kernels/$kver/scripts/basic/fixdep"
for f in GPL-2.0-only.kernel.txt Apache-2.0.kestrel.txt nvidia-open-gpu-kernel-modules.COPYING.txt; do
  printf 'stand-in licence placeholder\n' >"$stage/usr/share/kestrel/LICENSES/$f"
done
printf 'stand-in\n' >"$stage/usr/share/licenses/kestrel-nvidia-kmod/COPYING"
cp "$KESTREL_ROOT/keys/kestrel.crt" "$stage/usr/share/kestrel/kestrel.crt"
printf 'stand-in\n' >"$stage/usr/share/doc/kestrel-kernel/config-$kver"

nvrelease="0.standin.k${kversion//./_}_${tagrel}.fc${rel}"
kestrel_rpmbuild "$stage" "$kver" "$kversion" "$krelease" "$nvver" "$nvrelease" "$channel" "$rel" "$out"

jq -n --slurpfile want "$want" \
  '{schema: 1, name: "kestrel", standin: true, channel: $want[0].channel, kver: $want[0].kver, build_id: $want[0].build_id,
    kernel: $want[0].kernel, nvidia: $want[0].nvidia, fedora: $want[0].fedora,
    signing: {key: "none", rpm: {key: "none"}}}' >"$out/manifest.json"
install -m 0644 "$KESTREL_ROOT/keys/kestrel.crt" "$out/kestrel.crt"
install -m 0644 "$KESTREL_ROOT/keys/RPM-GPG-KEY-kestrel" "$out/RPM-GPG-KEY-kestrel"
cp -a "$stage/usr/share/kestrel/LICENSES" "$out/LICENSES"
ls -la "$out/rpms"
for r in "$out"/rpms/*.rpm; do
  printf '%s\n  provides: %s\n' "$(basename "$r")" "$(rpm -qp --provides "$r" 2>/dev/null | tr '\n' ';' | cut -c1-400)"
done

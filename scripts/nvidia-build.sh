#!/usr/bin/env bash
# Build the NVIDIA open kernel modules against the finished kernel tree.
#
#   nvidia-build.sh WANT_JSON SRC_DIR NV_DIR
#
# Downloads NVIDIA-kernel-module-source-<ver>.tar.xz for the version Terra
# ships, applies the CachyOS nvidia patches for this kernel major leniently
# (a patch that does not apply is skipped and recorded), builds with the same
# clang the kernel used, and leaves nvidia*.ko in NV_DIR/kernel-open.
#
# Writes NV_DIR/kestrel-nvidia.json.

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
need curl tar xz make clang ld.lld jq patch modinfo

want=${1:?}
src=${2:?}
nvdir=${3:?}
want=$(readlink -f "$want"); src=$(readlink -f "$src")

nvver=$(jget "$want" .nvidia.version)
nvurl=$(jget "$want" .nvidia.source_url)
patchsource=$(jget "$want" .kernel.patchsource)
kver=$(jget "$want" .kver)
[[ -f $src/vmlinux && -f $src/Module.symvers ]] || die "kernel tree at $src is not built"

work=$(dirname "$nvdir")
mkdir -p "$work"

group "Fetch NVIDIA kernel module source $nvver"
tarball="$work/NVIDIA-kernel-module-source-$nvver.tar.xz"
[[ -s $tarball ]] || fetch "$nvurl" "$tarball"
nv_sha=$(sha256_of "$tarball")
rm -rf "$nvdir"; mkdir -p "$nvdir"
tar -xJf "$tarball" -C "$nvdir" --strip-components=1
[[ -d $nvdir/kernel-open && -f $nvdir/kernel-open/Makefile ]] || die "unexpected NVIDIA tarball layout"
# NVIDIA's own version file is the truth for what we unpacked.
unpacked=$(grep -m1 -oE 'NVIDIA_VERSION = [0-9.]+' "$nvdir/version.mk" | awk '{print $3}')
[[ $unpacked == "$nvver" ]] || die "tarball says $unpacked, wanted $nvver"
endgroup

group "CachyOS nvidia patches (lenient)"
cd "$nvdir" || die "cannot enter $nvdir"
patch_records=()
mapfile -t nvpatches < <(jq -r '.kernel.nvidia_patches[]' "$want")
# CachyOS lists only the patches their PKGBUILD applies today. The directory
# for this major can hold more; we take exactly what the PKGBUILD names.
for p in "${nvpatches[@]}"; do
  f="$work/nvidia-$p"
  if ! fetch "$patchsource/misc/nvidia/$p" "$f"; then
    log "patch $p not downloadable, skipping"
    patch_records+=("$(jq -cn --arg p "$p" '{name:$p, status:"missing"}')")
    continue
  fi
  if patch --dry-run --forward -p1 <"$f" >/dev/null 2>&1; then
    patch --forward --no-backup-if-mismatch -p1 <"$f" >/dev/null
    log "applied $p"
    patch_records+=("$(jq -cn --arg p "$p" --arg sha "$(sha256_of "$f")" '{name:$p, sha256:$sha, status:"applied"}')")
  else
    log "patch $p does not apply to $nvver, skipping"
    patch_records+=("$(jq -cn --arg p "$p" --arg sha "$(sha256_of "$f")" '{name:$p, sha256:$sha, status:"skipped"}')")
  fi
done
endgroup

group "Build modules for $kver"
# Same flags CachyOS uses, minus their makepkg environment. CC must be the
# kernel's compiler; the kernel-open Makefile reads CONFIG_CC_VERSION_TEXT
# and would pick "clang" on its own, but we pass it so nothing is inferred.
make -C "$nvdir" \
  CC=clang LD=ld.lld LLVM=1 LLVM_IAS=1 \
  SYSSRC="$src" SYSOUT="$src" KERNEL_UNAME="$kver" \
  IGNORE_PREEMPT_RT_PRESENCE=1 IGNORE_CC_MISMATCH=yes \
  NV_EXCLUDE_KERNEL_MODULES="nvidia-vgpu-vfio" \
  CFLAGS= CXXFLAGS= LDFLAGS= \
  -j"$(nproc)" modules 2>&1 | tee "$nvdir/kestrel-nvidia-make.log" | grep -E 'error|warning: .*(defined but|implicit)|conftest|CONFTEST|^make' | head -100 || true
test "${PIPESTATUS[0]}" -eq 0 || die "nvidia make failed"
endgroup

group "Check"
mods=(nvidia nvidia-modeset nvidia-drm nvidia-uvm nvidia-peermem)
records=()
for m in "${mods[@]}"; do
  ko="$nvdir/kernel-open/$m.ko"
  [[ -f $ko ]] || die "$m.ko missing"
  vermagic=$(modinfo -F vermagic "$ko" | awk '{print $1}')
  [[ $vermagic == "$kver" ]] || die "$m.ko vermagic $vermagic != $kver"
  version=$(modinfo -F version "$ko" || true)
  if [[ $m != nvidia-peermem && -n $version && $version != "$nvver" ]]; then
    die "$m.ko version $version != $nvver"
  fi
  log "$m.ko vermagic=$vermagic version=${version:-n/a}"
  records+=("$(jq -cn --arg m "$m" --arg v "${version:-}" '{module:$m, version:$v}')")
done
endgroup

jq -n \
  --arg version "$nvver" --arg tarball_sha256 "$nv_sha" --arg url "$nvurl" \
  --argjson patches "$(printf '%s\n' "${patch_records[@]:-}" | jq -cs 'map(select(. != null and . != ""))')" \
  --argjson modules "$(printf '%s\n' "${records[@]}" | jq -cs .)" \
  '{version:$version, source_url:$url, tarball_sha256:$tarball_sha256, patches:$patches, modules:$modules}' \
  >"$nvdir/kestrel-nvidia.json"
cat "$nvdir/kestrel-nvidia.json"

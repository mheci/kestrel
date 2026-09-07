#!/usr/bin/env bash
# Turn the built kernel tree and NVIDIA modules into the kestrel file tree and RPMs.
#
#   package.sh WANT_JSON SRC_DIR NV_DIR OUT_DIR
#
# Produces in OUT_DIR:
#   rpms/kestrel-kernel-*.rpm, kestrel-kernel-devel-*.rpm, kestrel-nvidia-kmod-*.rpm
#   manifest.json           provenance and the config delta
#   kestrel.crt             the public signing certificate
#   LICENSES/               GPL-2.0 (kernel), MIT + GPL (NVIDIA), Apache-2.0 (kestrel)
#
# Layout inside the RPMs (Fedora shape, so dracut and bootc find everything):
#   /usr/lib/modules/<kver>/vmlinuz            signed with sbsign (kestrel key)
#   /usr/lib/modules/<kver>/System.map, config, modules.order, modules.builtin*
#   /usr/lib/modules/<kver>/kernel/**/*.ko.zst  signed (sha512) and zstd
#   /usr/lib/modules/<kver>/extra/nvidia/*.ko.zst
#   /usr/lib/modules/<kver>/build -> /usr/src/kernels/<kver>
#   /usr/src/kernels/<kver>                     headers, scripts, Module.symvers, objtool

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
need make jq zstd sbsign sbverify openssl rpmbuild rpmsign rpmkeys gpg depmod modinfo llvm-strip ccache clang

want=${1:?}
src=${2:?}
nvdir=${3:?}
out=${4:?}
want=$(readlink -f "$want"); src=$(readlink -f "$src"); nvdir=$(readlink -f "$nvdir")
mkdir -p "$out"; out=$(readlink -f "$out")

kver=$(jget "$want" .kver)
kversion=$(jget "$want" .kernel.version)
tagrel=$(jget "$want" .kernel.tagrel)
channel=$(jget "$want" .channel)
nvver=$(jget "$want" .nvidia.version)
rel=$(jget "$want" .fedora.release)
[[ -f $src/kestrel-prepare.json && -f $nvdir/kestrel-nvidia.json ]] || die "stage records missing"
[[ $(make -s -C "$src" LLVM=1 CC="ccache clang" HOSTCC="ccache clang" kernelrelease) == "$kver" ]] || die "tree kernelrelease mismatch"

stage=$(mktemp -d "${TMPDIR:-/tmp}/kestrel-stage.XXXXXX")
modlib="$stage/usr/lib/modules/$kver"
export CCACHE_DIR=${CCACHE_DIR:-$HOME/.cache/kestrel-ccache}
export CCACHE_BASEDIR=$src CCACHE_NOHASHDIR=1 CCACHE_COMPILERCHECK=content
flags=(LLVM=1 LLVM_IAS=1 CC="ccache clang" HOSTCC="ccache clang" LD=ld.lld)
signkey="$src/certs/kestrel-keypair.pem"
cert="$src/certs/kestrel.crt"
hash_algo=$(grep -Po 'CONFIG_MODULE_SIG_HASH="\K[^"]*' "$src/.config")

group "modules_install (signed by Kbuild, zstd)"
# Kbuild signs every module during modules_install when MODULE_SIG_ALL=y,
# strips with INSTALL_MOD_STRIP, then compresses with MODULE_COMPRESS_ZSTD.
# DEPMOD is pointed at a no-op: depmod runs inside the consumer image.
make -C "$src" "${flags[@]}" -j"$(nproc)" INSTALL_MOD_PATH="$stage/usr" INSTALL_MOD_STRIP=1 \
  DEPMOD=/bin/true ZSTD_CLEVEL=19 modules_install >"$out/modules_install.log" 2>&1 \
  || { tail -50 "$out/modules_install.log" >&2; die "modules_install failed"; }
rm -f "$modlib/build" "$modlib/source"
n_ko=$(find "$modlib/kernel" -name '*.ko.zst' | wc -l)
[[ $n_ko -gt 1000 ]] || die "only $n_ko modules installed"
log "$n_ko in-tree modules installed"
endgroup

group "NVIDIA modules: strip, sign, compress"
mkdir -p "$modlib/extra/nvidia"
for ko in "$nvdir"/kernel-open/nvidia*.ko; do
  name=$(basename "$ko")
  cp "$ko" "$modlib/extra/nvidia/$name"
  llvm-strip --strip-debug "$modlib/extra/nvidia/$name"
  "$src/scripts/sign-file" "$hash_algo" "$signkey" "$cert" "$modlib/extra/nvidia/$name"
  zstd -q --rm -19 -T0 "$modlib/extra/nvidia/$name"
done
ls -la "$modlib/extra/nvidia"
endgroup

group "Kernel image, System.map, config"
bz="$src/arch/x86/boot/bzImage"
# Secure Boot ready: sign the EFI stub image with the same project key.
sbsign --key "$src/certs/kestrel-signing-key.pem" --cert "$cert" --output "$modlib/vmlinuz" "$bz" 2>/dev/null
sbverify --cert "$cert" "$modlib/vmlinuz" >/dev/null || die "sbverify failed on vmlinuz"
chmod 0755 "$modlib/vmlinuz"
install -m 0644 "$src/System.map" "$modlib/System.map"
install -m 0644 "$src/.config" "$modlib/config"
# symvers as Fedora ships it, next to the modules.
xz -9 -c "$src/Module.symvers" >"$modlib/symvers.xz"
endgroup

group "Headers (kernel-devel) via install-extmod-build"
devel="$stage/usr/src/kernels/$kver"
mkdir -p "$devel"
make -C "$src" "${flags[@]}" -s run-command KBUILD_RUN_COMMAND="\${srctree}/scripts/package/install-extmod-build $devel"
install -m 0644 "$src/.config" "$devel/.config"
install -m 0644 "$src/System.map" "$devel/System.map"
install -m 0644 "$src/Module.symvers" "$devel/Module.symvers"
cp -a "$src"/localversion.* "$devel/" 2>/dev/null || true
printf '%s\n' "$kver" >"$devel/kestrel.release"
# vmlinux.h is what the CachyOS headers ship for BPF CO-RE consumers; skip
# (needs bpftool build) unless already present.
ln -sfn "/usr/src/kernels/$kver" "$modlib/build"
find "$devel" -name '*.cmd' -delete
du -sh "$devel"
endgroup

group "Documentation, licence, cert"
mkdir -p "$stage/usr/share/kestrel/LICENSES" "$stage/usr/share/licenses/kestrel-nvidia-kmod" "$stage/usr/share/doc/kestrel-kernel"
install -m 0644 "$src/COPYING" "$stage/usr/share/kestrel/LICENSES/GPL-2.0-only.kernel.txt"
nv_license=$(find "$nvdir" -maxdepth 2 -name COPYING | head -1)
[[ -n $nv_license ]] || die "NVIDIA COPYING not found"
install -m 0644 "$nv_license" "$stage/usr/share/licenses/kestrel-nvidia-kmod/COPYING"
install -m 0644 "$nv_license" "$stage/usr/share/kestrel/LICENSES/nvidia-open-gpu-kernel-modules.COPYING.txt"
install -m 0644 "$KESTREL_ROOT/LICENSE" "$stage/usr/share/kestrel/LICENSES/Apache-2.0.kestrel.txt"
install -m 0644 "$cert" "$stage/usr/share/kestrel/kestrel.crt"
install -m 0644 "$src/kestrel-final.config" "$stage/usr/share/doc/kestrel-kernel/config-$kver"
endgroup

group "Verify signatures before packaging"
# Every module carries a signature block ending in the magic string.
bad=0
while IFS= read -r -d '' f; do
  if ! zstd -dcq "$f" | tail -c 28 | grep -q '~Module signature appended~'; then
    log "unsigned: $f"; bad=$((bad+1))
  fi
done < <(find "$modlib" -name '*.ko.zst' -print0)
[[ $bad -eq 0 ]] || die "$bad unsigned modules"
# Verify one in-tree and one NVIDIA module against the cert.
python3 "$KESTREL_ROOT/scripts/modsig.py" --cert "$cert" "$modlib/extra/nvidia/nvidia.ko.zst" "$(find "$modlib/kernel" -name '*.ko.zst' | head -1)"
endgroup

group "depmod sanity on the staged tree"
depmod -b "$stage/usr" -e -F "$src/System.map" "$kver" >"$out/depmod.log" 2>&1 || { cat "$out/depmod.log" >&2; die "depmod failed"; }
head -20 "$out/depmod.log"
if grep -q -i -E 'needs unknown symbol|error' "$out/depmod.log"; then die "depmod reported problems"; fi
# The depmod output ships with the RPM so a plain `rpm -U` gives a working
# module tree; kestrel-install runs depmod again after everything is in place.
endgroup

group "rpmbuild"
krelease=$(jget "$want" .kernel.rpm_release)
[[ "${kversion}-${krelease}.x86_64" == "$kver" ]] || die "rpm_release $krelease does not reproduce kver $kver"
nvrelease="1.k${kversion//./_}_${tagrel}.kestrel.fc${rel}"
kestrel_rpmbuild "$stage" "$kver" "$kversion" "$krelease" "$nvver" "$nvrelease" "$channel" "$rel" "$out"
endgroup

group "Sign RPMs"
# OpenPGP signature with the project RPM key when the secret is present.
# rpm 6 (Fedora 44+) is moving to enforcing signature checks; kestrel-install
# imports the public key and verifies before installing.
rpm_key_kind=none
rpm_key_fpr=""
if [[ -n ${KESTREL_RPM_GPG_KEY_FILE:-} && -s ${KESTREL_RPM_GPG_KEY_FILE:-} ]]; then
  export GNUPGHOME
  GNUPGHOME=$(mktemp -d)
  gpg --batch --quiet --import "$KESTREL_RPM_GPG_KEY_FILE"
  rpm_key_fpr=$(gpg --batch --with-colons --list-secret-keys | awk -F: '/^fpr/{print $10; exit}')
  [[ -n $rpm_key_fpr ]] || die "no secret key in KESTREL_RPM_GPG_KEY_FILE"
  pub_fpr=$(gpg --batch --with-colons --show-keys "$KESTREL_ROOT/keys/RPM-GPG-KEY-kestrel" | awk -F: '/^fpr/{print $10; exit}')
  [[ $pub_fpr == "$rpm_key_fpr" ]] || die "secret RPM key $rpm_key_fpr does not match keys/RPM-GPG-KEY-kestrel ($pub_fpr)"
  rpmsign --define "_openpgp_sign gpg" --define "_gpg_path $GNUPGHOME" --define "_openpgp_sign_id $rpm_key_fpr" \
    --addsign "$out"/rpms/*.rpm >"$out/rpmsign.log" 2>&1 || { cat "$out/rpmsign.log" >&2; die "rpmsign failed"; }
  rm -rf "$GNUPGHOME"; unset GNUPGHOME
  # Prove it the way a consumer will: import the public key, check every package.
  rpmkeys --import "$KESTREL_ROOT/keys/RPM-GPG-KEY-kestrel"
  rpmkeys --define "_pkgverify_level all" --checksig "$out"/rpms/*.rpm || die "rpmkeys --checksig failed"
  rpm_key_kind=project
  log "RPMs signed with $rpm_key_fpr"
else
  log "no KESTREL_RPM_GPG_KEY_FILE: RPMs stay unsigned (local build)"
fi
ls -la "$out/rpms"
for r in "$out"/rpms/*.rpm; do
  printf '%s\n  provides: %s\n' "$(basename "$r")" "$(rpm -qp --provides "$r" 2>/dev/null | tr '\n' ';' | cut -c1-300)"
done
endgroup

group "manifest.json"
built_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
jq -n \
  --slurpfile want "$want" \
  --slurpfile prep "$src/kestrel-prepare.json" \
  --slurpfile nv "$nvdir/kestrel-nvidia.json" \
  --arg built_at "$built_at" \
  --arg cert_fpr "$(openssl x509 -in "$cert" -noout -fingerprint -sha256 | cut -d= -f2)" \
  --arg cert_subject "$(openssl x509 -in "$cert" -noout -subject | sed 's/^subject=//')" \
  --arg cert_not_after "$(openssl x509 -in "$cert" -noout -enddate | cut -d= -f2)" \
  --arg rpm_key_kind "$rpm_key_kind" --arg rpm_key_fpr "$rpm_key_fpr" \
  --arg workflow_run "${GITHUB_SERVER_URL:-}/${GITHUB_REPOSITORY:-}/actions/runs/${GITHUB_RUN_ID:-local}" \
  --arg kestrel_commit "${GITHUB_SHA:-$(git -C "$KESTREL_ROOT" rev-parse HEAD 2>/dev/null || echo unknown)}" \
  --argjson rpms "$(cd "$out/rpms" && for r in *.rpm; do jq -cn --arg n "$r" --arg s "$(sha256_of "$r")" '{name:$n, sha256:$s}'; done | jq -cs .)" \
  --argjson n_modules "$n_ko" \
  '{
    schema: 1,
    name: "kestrel",
    channel: $want[0].channel,
    kver: $want[0].kver,
    build_id: $want[0].build_id,
    built_at: $built_at,
    kestrel: {repository: "https://github.com/mheci/kestrel", commit: $kestrel_commit, workflow_run: $workflow_run, tree_hash: $want[0].kestrel.tree_hash},
    kernel: ($want[0].kernel + {tarball_sha256: $prep[0].tarball_sha256, gpg_signer: $prep[0].gpg_signer,
             in_tree_modules: $n_modules, toolchain: $prep[0].toolchain, applied_patches: $prep[0].kernel_patches,
             config_delta_from_cachyos: $prep[0].config_delta}),
    nvidia: ($want[0].nvidia + {tarball_sha256: $nv[0].tarball_sha256, patches: $nv[0].patches, modules: $nv[0].modules}),
    fedora: $want[0].fedora,
    signing: {key: $prep[0].signing_key, algorithm: "RSA-4096", module_hash: "sha512",
              certificate: {subject: $cert_subject, sha256_fingerprint: $cert_fpr, not_after: $cert_not_after},
              vmlinuz: "sbsign (Authenticode) with the same key",
              rpm: {key: $rpm_key_kind, openpgp_fingerprint: $rpm_key_fpr, public_key: "/usr/share/kestrel/RPM-GPG-KEY-kestrel"}},
    rpms: $rpms
  }' >"$out/manifest.json"
install -m 0644 "$cert" "$out/kestrel.crt"
install -m 0644 "$KESTREL_ROOT/keys/RPM-GPG-KEY-kestrel" "$out/RPM-GPG-KEY-kestrel"
cp -a "$stage/usr/share/kestrel/LICENSES" "$out/LICENSES"
jq -c '{channel, kver, build_id, nvidia: .nvidia.version, signing: .signing.key}' "$out/manifest.json"
endgroup

rm -rf "$stage"

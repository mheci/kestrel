#!/usr/bin/env bash
# Prepare the kernel source tree for one channel inside the Fedora builder.
#
#   kernel-prepare.sh WANT_JSON CONFIG_CACHYOS SRC_DIR
#
# Steps, in order, each recorded in SRC_DIR/kestrel-prepare.json:
#   1. Download and GPG-verify the CachyOS tarball named by want.json, unpack.
#   2. Apply the kernel patches the PKGBUILD lists (dkms-clang, scheduler).
#   3. Install the CachyOS config verbatim, replay the PKGBUILD knobs with
#      scripts/config (the same way prepare() does), then apply the kestrel
#      delta. Every option kestrel changes is listed in the JSON record.
#   4. make olddefconfig and record the resulting kernelrelease, which must
#      equal want.kver or the stage fails.
#
# The signing key comes from KESTREL_SIGNING_KEY_FILE (path). Without it the
# script generates a throwaway key so local builds still work; the manifest
# then says signing.key = "ephemeral".

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
need curl gpg tar jq python3 make clang ld.lld llvm-ar openssl pahole ccache

want=${1:?}
cfg=${2:?}
src=${3:?}
want=$(readlink -f "$want"); cfg=$(readlink -f "$cfg")

srctag=$(jget "$want" .kernel.srctag)
kver=$(jget "$want" .kernel.version)
tagrel=$(jget "$want" .kernel.tagrel)
want_kver=$(jget "$want" .kver)
suffix=${want_kver#"${kver}-${tagrel}-"}
patchsource=$(jget "$want" .kernel.patchsource)
source_url=$(jget "$want" .kernel.source_url)

work=$(dirname "$src")
mkdir -p "$work"

group "Fetch and verify $srctag"
tarball="$work/$srctag.tar.gz"
if [[ ! -s $tarball ]]; then
  fetch "$source_url" "$tarball"
fi
fetch "$source_url.asc" "$tarball.asc"
export GNUPGHOME
GNUPGHOME=$(mktemp -d)
gpg --batch --quiet --import "$KESTREL_ROOT"/keys/cachyos-*.asc
gpg --batch --status-fd 1 --verify "$tarball.asc" "$tarball" | tee "$work/gpg-status.txt" | grep -q '^\[GNUPG:\] VALIDSIG' \
  || die "GPG verification of $srctag failed"
signer=$(grep '^\[GNUPG:\] VALIDSIG' "$work/gpg-status.txt" | awk '{print $NF}')
log "signed by $signer"
rm -rf "$GNUPGHOME"; unset GNUPGHOME
tar_sha=$(sha256_of "$tarball")
endgroup

group "Unpack"
rm -rf "$src"
mkdir -p "$src"
tar -xzf "$tarball" -C "$src" --strip-components=1
[[ -f $src/Makefile && -d $src/kernel ]] || die "unexpected tarball layout"
endgroup

cd "$src" || die "cannot enter $src"

group "Version files"
# Same mechanism the PKGBUILD uses: localversion files give -<tagrel>-<suffix>.
printf -- '-%s\n' "$tagrel" >localversion.10-pkgrel
printf -- '-%s\n' "$suffix" >localversion.20-pkgname
endgroup

group "Kernel patches"
applied=()
mapfile -t patches < <(jq -r '.kernel.kernel_patches[]' "$want")
for p in "${patches[@]}"; do
  f="$work/$(basename "$p")"
  fetch "$patchsource/$p" "$f"
  log "applying $p ($(sha256_of "$f" | cut -c1-12))"
  patch --forward --no-backup-if-mismatch -p1 <"$f"
  applied+=("$(jq -cn --arg p "$p" --arg sha "$(sha256_of "$f")" '{path:$p, sha256:$sha}')")
done
endgroup

group "Config: CachyOS file plus PKGBUILD knobs"
cp "$cfg" .config
knob() { jq -r --arg k "$1" '.kernel.knobs[$k] // empty' "$want"; }
cfgset() { scripts/config "$@"; }

# _processor_opt is empty upstream (their PKGBUILD then picks native, their
# repo builds pass GENERIC_V3). kestrel is x86-64-v3 only.
cfgset -e GENERIC_CPU -d MZEN4 -d X86_NATIVE_CPU --set-val X86_64_VERSION 3

[[ $(knob _cachy_config) == yes ]] && cfgset -e CACHY

case "$(knob _cpusched)" in
  cachyos|bore|hardened) cfgset -e SCHED_BORE ;;
  bmq) cfgset -e SCHED_ALT -e SCHED_BMQ ;;
  eevdf) ;;
  rt) cfgset -e PREEMPT_RT ;;
  rt-bore) cfgset -e SCHED_BORE -e PREEMPT_RT ;;
  *) die "unknown _cpusched" ;;
esac

[[ $(knob _use_kcfi) == yes ]] && cfgset -e ARCH_SUPPORTS_CFI_CLANG -e CFI_CLANG -e CFI_AUTO_DEFAULT

# LTO: kestrel builds both channels with Clang ThinLTO (decision, round 6).
cfgset -e LTO_CLANG_THIN

case "$(knob _HZ_ticks)" in
  100|250|500|600|750|1000) cfgset -d HZ_300 -e "HZ_$(knob _HZ_ticks)" --set-val HZ "$(knob _HZ_ticks)" ;;
  300) cfgset -e HZ_300 --set-val HZ 300 ;;
  *) die "unknown _HZ_ticks" ;;
esac

[[ $(knob _per_gov) == yes ]] && cfgset -d CPU_FREQ_DEFAULT_GOV_SCHEDUTIL -e CPU_FREQ_DEFAULT_GOV_PERFORMANCE

case "$(knob _tickrate)" in
  periodic) cfgset -d NO_HZ_IDLE -d NO_HZ_FULL -d NO_HZ -d NO_HZ_COMMON -e HZ_PERIODIC ;;
  idle) cfgset -d HZ_PERIODIC -d NO_HZ_FULL -e NO_HZ_IDLE -e NO_HZ -e NO_HZ_COMMON ;;
  full) cfgset -d HZ_PERIODIC -d NO_HZ_IDLE -d CONTEXT_TRACKING_FORCE -e NO_HZ_FULL_NODEF -e NO_HZ_FULL -e NO_HZ -e NO_HZ_COMMON -e CONTEXT_TRACKING ;;
  *) die "unknown _tickrate" ;;
esac

sched=$(knob _cpusched)
if [[ $sched != rt && $sched != rt-bore ]]; then
  case "$(knob _preempt)" in
    full) cfgset -e PREEMPT_DYNAMIC -e PREEMPT -d PREEMPT_VOLUNTARY -d PREEMPT_LAZY -d PREEMPT_NONE ;;
    lazy) cfgset -e PREEMPT_DYNAMIC -d PREEMPT -d PREEMPT_VOLUNTARY -e PREEMPT_LAZY -d PREEMPT_NONE ;;
    voluntary) cfgset -d PREEMPT_DYNAMIC -d PREEMPT -e PREEMPT_VOLUNTARY -d PREEMPT_LAZY -d PREEMPT_NONE ;;
    none) cfgset -d PREEMPT_DYNAMIC -d PREEMPT -d PREEMPT_VOLUNTARY -d PREEMPT_LAZY -e PREEMPT_NONE ;;
    *) die "unknown _preempt" ;;
  esac
fi

[[ $(knob _cc_harder) == yes ]] && cfgset -d CC_OPTIMIZE_FOR_PERFORMANCE -e CC_OPTIMIZE_FOR_PERFORMANCE_O3

if [[ $(knob _tcp_bbr3) == yes ]]; then
  cfgset -m TCP_CONG_CUBIC -d DEFAULT_CUBIC -e TCP_CONG_BBR -e DEFAULT_BBR --set-str DEFAULT_TCP_CONG bbr \
    -m NET_SCH_FQ_CODEL -e NET_SCH_FQ -d DEFAULT_FQ_CODEL -e DEFAULT_FQ
fi

case "$(knob _hugepage)" in
  always) cfgset -d TRANSPARENT_HUGEPAGE_MADVISE -e TRANSPARENT_HUGEPAGE_ALWAYS ;;
  madvise) cfgset -d TRANSPARENT_HUGEPAGE_ALWAYS -e TRANSPARENT_HUGEPAGE_MADVISE ;;
  *) die "unknown _hugepage" ;;
esac

# The LTS PKGBUILD enables USER_NS explicitly; the stable one has it on already.
cfgset -e USER_NS
endgroup

group "Config: kestrel delta for Fedora bootc consumers"
# Every line here is a deliberate difference from CachyOS and is listed in the
# manifest so a reader can audit it.
delta=()
note() { delta+=("$1"); log "delta: $1"; }

# SELinux is the LSM Fedora's userspace expects. CachyOS leaves it built but
# not in the LSM list and defaults to DAC.
cfgset --set-str LSM "landlock,lockdown,yama,integrity,selinux,bpf"
cfgset -d DEFAULT_SECURITY_DAC -e DEFAULT_SECURITY_SELINUX
note 'CONFIG_LSM="landlock,lockdown,yama,integrity,selinux,bpf" (CachyOS: no selinux in the list)'
note 'CONFIG_DEFAULT_SECURITY_SELINUX=y (CachyOS: DAC)'

# Persistent project key instead of a fresh ECDSA key per build.
mkdir -p certs
if [[ -n ${KESTREL_SIGNING_KEY_FILE:-} && -s ${KESTREL_SIGNING_KEY_FILE:-} ]]; then
  cp "$KESTREL_SIGNING_KEY_FILE" certs/kestrel-signing-key.pem
  key_kind=project
else
  log "no KESTREL_SIGNING_KEY_FILE, generating an ephemeral RSA key for this build"
  openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:4096 -out certs/kestrel-signing-key.pem 2>/dev/null
  key_kind=ephemeral
fi
chmod 600 certs/kestrel-signing-key.pem
if [[ $key_kind == project ]]; then
  cp "$KESTREL_ROOT/keys/kestrel.crt" certs/kestrel.crt
else
  openssl req -new -x509 -key certs/kestrel-signing-key.pem -days 3650 -sha512 -subj "/O=kestrel/CN=kestrel ephemeral build key" -out certs/kestrel.crt
fi
# The kernel's MODULE_SIG_KEY wants key and cert in one PEM file.
cat certs/kestrel-signing-key.pem certs/kestrel.crt >certs/kestrel-keypair.pem
chmod 600 certs/kestrel-keypair.pem
diff <(openssl pkey -in certs/kestrel-signing-key.pem -pubout 2>/dev/null) <(openssl x509 -in certs/kestrel.crt -pubkey -noout) >/dev/null \
  || die "signing key does not match keys/kestrel.crt"
cfgset --set-str MODULE_SIG_KEY "certs/kestrel-keypair.pem"
cfgset -d MODULE_SIG_KEY_TYPE_ECDSA -e MODULE_SIG_KEY_TYPE_RSA
# The MODULE_SIG_KEY certificate is compiled into the builtin trusted keyring
# by Kbuild itself, so SYSTEM_TRUSTED_KEYS stays empty (adding the same cert
# there would only load it twice).
cfgset --set-str SYSTEM_TRUSTED_KEYS ""
note 'CONFIG_MODULE_SIG_KEY=certs/kestrel-keypair.pem, RSA-4096 persistent project key (CachyOS: per-build ECDSA P-384)'

# Build-time only: compressed DWARF halves the tree size on a 4 vCPU runner.
# Debug info is stripped from everything shipped; BTF and ORC are unaffected.
cfgset -d DEBUG_INFO_COMPRESSED_NONE -e DEBUG_INFO_COMPRESSED_ZSTD
note 'CONFIG_DEBUG_INFO_COMPRESSED_ZSTD=y (CachyOS: NONE; build-time only)'

# Rust: Kconfig forbids RUST together with DEBUG_INFO_BTF and LTO. CachyOS's
# own ThinLTO packages end up with Rust off for the same reason. Say so here
# instead of letting olddefconfig do it silently.
cfgset -d RUST
note 'CONFIG_RUST=n (implied by BTF + LTO; matches the shipped CachyOS LTO kernels)'

# No AutoFDO: CachyOS's profile is not published.
cfgset -d AUTOFDO_CLANG -d PROPELLER_CLANG
note 'CONFIG_AUTOFDO_CLANG=n (CachyOS ships stable with a private AutoFDO profile)'

# Fedora's dracut and bootc do not need anything else from us here.
endgroup

group "olddefconfig with the kestrel toolchain"
export KBUILD_BUILD_HOST=kestrel
KBUILD_BUILD_USER="kestrel-$(jget "$want" .channel)"; export KBUILD_BUILD_USER
export KBUILD_BUILD_TIMESTAMP
KBUILD_BUILD_TIMESTAMP=$(date -Ru -d "@${SOURCE_DATE_EPOCH:-$(date +%s)}")
# Same CC string as kernel-build.sh so Kbuild never sees a compiler change.
export CCACHE_DIR=${CCACHE_DIR:-$HOME/.cache/kestrel-ccache}
mkdir -p "$CCACHE_DIR"
make LLVM=1 LLVM_IAS=1 CC="ccache clang" HOSTCC="ccache clang" LD=ld.lld olddefconfig
got_kver=$(make -s LLVM=1 CC="ccache clang" HOSTCC="ccache clang" kernelrelease)
[[ $got_kver == "$want_kver" ]] || die "kernelrelease $got_kver != wanted $want_kver"
log "kernelrelease $got_kver"

# Assert the config we asked for survived olddefconfig.
assert_cfg() {
  grep -qx "$1" .config || die "config assertion failed: $1"
}
assert_cfg 'CONFIG_LTO_CLANG_THIN=y'
assert_cfg 'CONFIG_CC_OPTIMIZE_FOR_PERFORMANCE_O3=y'
assert_cfg 'CONFIG_X86_64_VERSION=3'
assert_cfg 'CONFIG_DEBUG_INFO_BTF=y'
grep -qx 'CONFIG_DEBUG_INFO_DWARF5=y' .config || grep -qx 'CONFIG_DEBUG_INFO_DWARF4=y' .config || die "config assertion failed: full DWARF debug info"
log "debug info: $(grep -oE '^CONFIG_DEBUG_INFO_DWARF[45]=y' .config)"
assert_cfg 'CONFIG_DEFAULT_SECURITY_SELINUX=y'
assert_cfg 'CONFIG_MODULE_SIG_ALL=y'
assert_cfg 'CONFIG_MODULE_SIG_KEY_TYPE_RSA=y'
assert_cfg "CONFIG_HZ_$(knob _HZ_ticks)=y"
[[ $(knob _cachy_config) != yes ]] || assert_cfg 'CONFIG_CACHY=y'
grep -q '^CONFIG_DEBUG_INFO_REDUCED=y' .config && die "DEBUG_INFO_REDUCED must stay off"
grep -q '^CONFIG_CC_OPTIMIZE_FOR_SIZE=y' .config && die "-Os must stay off"
endgroup

group "Record"
jq -n \
  --arg srctag "$srctag" --arg tarball_sha256 "$tar_sha" --arg signer "$signer" \
  --arg kver "$got_kver" --arg key_kind "$key_kind" \
  --arg cc "$(clang --version | head -1)" --arg ld "$(ld.lld --version | head -1)" \
  --arg pahole "$(pahole --version)" \
  --argjson patches "$(printf '%s\n' "${applied[@]:-}" | jq -cs 'map(select(. != null and . != ""))')" \
  --argjson delta "$(printf '%s\n' "${delta[@]}" | jq -R . | jq -cs .)" \
  '{srctag:$srctag, tarball_sha256:$tarball_sha256, gpg_signer:$signer, kver:$kver, signing_key:$key_kind,
    toolchain:{cc:$cc, ld:$ld, pahole:$pahole}, kernel_patches:$patches, config_delta:$delta}' \
  >kestrel-prepare.json
cp .config kestrel-final.config
cat kestrel-prepare.json
endgroup

#!/usr/bin/env bash
# Compile the prepared kernel tree, with a time budget.
#
#   kernel-build.sh SRC_DIR BUDGET_SECONDS
#
# Exit codes:
#   0   build finished (vmlinux, modules, bzImage all present)
#   75  budget ran out; ccache holds the progress, run again to continue
#   1   the build failed
#
# ccache: CCACHE_DIR must point at a directory that the caller saves and
# restores between stages. The compile itself is a plain `make`, so a
# resumed stage re-walks the tree, hits the cache for every object that was
# already built, and continues from where the last stage stopped.
#
# ThinLTO: vmlinux.o is linked in one step at the end and cannot be cached
# by ccache. The final link of a full kernel takes roughly 15 to 25 minutes
# on 4 vCPU, so the budget must leave at least that much room.

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
need make clang ld.lld ccache pahole

src=${1:?}
budget=${2:?}
cd "$src"

export CCACHE_DIR=${CCACHE_DIR:-$HOME/.cache/kestrel-ccache}
mkdir -p "$CCACHE_DIR"
# With ThinLTO the objects are bitcode; ccache stores them like any other
# output. The cache must hold one whole build: if it were smaller, the
# resumed stage would evict entries in the same order make asks for them
# and rebuild everything. 9G covers a full tree with room to spare.
export CCACHE_BASEDIR=$src
export CCACHE_SLOPPINESS=time_macros,locale,include_file_mtime,include_file_ctime
export CCACHE_COMPILERCHECK=content
export CCACHE_NOHASHDIR=1
export CCACHE_MAXSIZE=${CCACHE_MAXSIZE:-9G}
export CCACHE_COMPRESS=1
export CCACHE_COMPRESSLEVEL=${CCACHE_COMPRESSLEVEL:-1}
ccache --zero-stats >/dev/null

jobs=$(nproc)
flags=(LLVM=1 LLVM_IAS=1 CC="ccache clang" HOSTCC="ccache clang" LD=ld.lld)
export KBUILD_BUILD_HOST=kestrel
export KBUILD_BUILD_USER="kestrel"
export KBUILD_BUILD_TIMESTAMP
KBUILD_BUILD_TIMESTAMP=$(date -Ru -d "@${SOURCE_DATE_EPOCH:-$(date +%s)}")

group "ccache before"
ccache --show-stats | sed -n 1,12p
endgroup

group "make all (budget ${budget}s, -j${jobs})"
start=$(date +%s)
set +e
timeout --signal=INT --kill-after=60 "$budget" make "${flags[@]}" -j"$jobs" all 2>&1 | tee kestrel-make.log | grep -v -E '^\s*(CC|AS|LD|AR|OBJCOPY|HOSTCC|HOSTLD|CHECK|CALL|GEN|MODPOST|BTF|LTO|UPD|WRAP|SYMLINK|MKDIR|CHK|DESCEND|INSTALL|HDRINST|MODINFO|COPY|STRIP|ZSTD|POLICY|MKELF|SORTTAB|RELOCS|VOFFSET|ZOFFSET|LDS|SYSHDR|SYSTBL|ASN.1|EXTRACT_CERTS|CERT|OBJDUMP|MKCAP|MKREGTABLE|NM|KSYMS|RSTGEN|HOSTCXX|CXX|PERL|PYTHON|LEX|YACC|BISON|CPP|UNROLL|SHIPPED|DTC|MKPIGGY|ZSTD22|XZ_DATA|XZKERN|MODFINAL|DTCO|RUSTC|BINDGEN|EXPORTS)\s' 
rc=${PIPESTATUS[0]}
set -e
elapsed=$(( $(date +%s) - start ))
endgroup

group "ccache after"
ccache --show-stats | sed -n 1,12p
du -sh "$CCACHE_DIR"
endgroup

if [[ $rc -eq 124 || $rc -eq 137 ]]; then
  log "budget exhausted after ${elapsed}s; ccache saved the progress"
  gh_output kernel_done false
  exit 75
fi
if [[ $rc -ne 0 ]]; then
  log "make failed with $rc after ${elapsed}s"
  tail -n 80 kestrel-make.log >&2
  gh_output kernel_done false
  exit 1
fi

[[ -f vmlinux && -f arch/x86/boot/bzImage && -f modules.order && -f Module.symvers ]] \
  || die "make returned 0 but outputs are missing"
log "kernel built in ${elapsed}s: $(stat -c %s arch/x86/boot/bzImage) bytes bzImage"
gh_output kernel_done true

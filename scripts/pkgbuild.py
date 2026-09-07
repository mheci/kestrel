#!/usr/bin/env python3
"""Read the facts kestrel needs out of a CachyOS PKGBUILD without executing it.

The PKGBUILD is upstream code. Sourcing it in bash would run it, so this reads
the handful of assignments the build depends on with regular expressions and
refuses anything that does not look like the shapes it knows.

Usage: pkgbuild.py PKGBUILD_FILE  -> JSON on stdout
"""

import hashlib
import json
import re
import sys

KNOBS = (
    "_cachy_config",
    "_cpusched",
    "_cc_harder",
    "_per_gov",
    "_tcp_bbr3",
    "_HZ_ticks",
    "_tickrate",
    "_preempt",
    "_hugepage",
    "_processor_opt",
    "_use_llvm_lto",
    "_use_kcfi",
    "_autofdo",
    "_propeller",
)

ASSIGN_RE = re.compile(r'^(?P<name>_major|_minor|_tagrel|pkgrel|_nv_ver|_patchsource)=(?P<val>"[^"]*"|\S+)\s*$', re.M)
KNOB_RE = re.compile(r'^: "\$\{(?P<name>_[A-Za-z0-9_]+):=(?P<val>[^}]*)\}"\s*$', re.M)
NV_PATCH_RE = re.compile(r'\$\{_patchsource\}/misc/nvidia/(?P<name>[A-Za-z0-9._-]+\.patch)')
KERNEL_PATCH_RE = re.compile(r'\$\{_patchsource\}/(?P<path>(?:sched|misc)/(?!nvidia/)[A-Za-z0-9._/-]+\.patch)')
SRCNAME_RE = re.compile(r'^_src(?:name|tag)=cachyos-\$\{_major\}\.\$\{_minor\}-\$\{_tagrel\}\s*$', re.M)
NUMERIC = re.compile(r'^[0-9]+$')
MAJOR = re.compile(r'^[0-9]+\.[0-9]+$')
NVVER = re.compile(r'^[0-9]+\.[0-9]+(\.[0-9]+)?$')


def fail(msg):
    print(f"pkgbuild.py: {msg}", file=sys.stderr)
    sys.exit(2)


def function_body(text, name):
    """Return the text of a top-level bash function, brace matched."""
    m = re.search(rf'^{re.escape(name)}\(\)\s*\{{', text, re.M)
    if not m:
        return ""
    depth = 0
    for i in range(m.end() - 1, len(text)):
        if text[i] == "{":
            depth += 1
        elif text[i] == "}":
            depth -= 1
            if depth == 0:
                return text[m.start():i + 1]
    return text[m.start():]


def main():
    if len(sys.argv) != 2:
        fail("usage: pkgbuild.py PKGBUILD")
    text = open(sys.argv[1], encoding="utf-8").read()

    values = {}
    for m in ASSIGN_RE.finditer(text):
        values[m.group("name")] = m.group("val").strip('"')
    for key in ("_major", "_minor", "_tagrel", "pkgrel", "_nv_ver", "_patchsource"):
        if key not in values:
            fail(f"{key} not found")
    if not MAJOR.match(values["_major"]):
        fail(f"_major has an unexpected shape: {values['_major']}")
    for key in ("_minor", "_tagrel", "pkgrel"):
        if not NUMERIC.match(values[key]):
            fail(f"{key} is not numeric: {values[key]}")
    if not NVVER.match(values["_nv_ver"]):
        fail(f"_nv_ver has an unexpected shape: {values['_nv_ver']}")
    if not SRCNAME_RE.search(text):
        fail("source tarball name formula changed upstream; refusing to guess")
    ps = values["_patchsource"]
    if not ps.startswith("https://raw.githubusercontent.com/cachyos/kernel-patches/master/${_major}"):
        fail(f"_patchsource changed upstream: {ps}")

    knobs = {}
    for m in KNOB_RE.finditer(text):
        if m.group("name") in KNOBS:
            knobs[m.group("name")] = m.group("val").strip('"')
    for k in ("_cpusched", "_HZ_ticks", "_tickrate", "_preempt", "_hugepage", "_cc_harder"):
        if k not in knobs:
            fail(f"knob {k} not found")

    # Scheduler patches follow the _cpusched case table in the PKGBUILD.
    sched = knobs["_cpusched"]
    kernel_patches = []
    if sched in ("bore", "rt-bore", "hardened"):
        kernel_patches.append("sched/0001-bore-cachy.patch")
    if sched == "bmq":
        kernel_patches.append("sched/0001-prjc-cachy.patch")
    if sched == "hardened":
        kernel_patches.append("misc/0001-hardened.patch")
    if sched in ("rt", "rt-bore"):
        kernel_patches.append("misc/0001-rt-i915.patch")
    if sched not in ("cachyos", "bore", "bmq", "hardened", "eevdf", "rt", "rt-bore"):
        fail(f"unknown _cpusched {sched}")
    # Any other kernel patch the PKGBUILD references explicitly (dkms-clang lives here).
    for m in KERNEL_PATCH_RE.finditer(text):
        p = m.group("path")
        if p not in kernel_patches and p not in ("sched/0001-bore-cachy.patch", "sched/0001-prjc-cachy.patch",
                                                  "misc/0001-hardened.patch", "misc/0001-rt-i915.patch"):
            kernel_patches.append(p)

    nvidia_patches = []
    for m in NV_PATCH_RE.finditer(text):
        if m.group("name") not in nvidia_patches:
            nvidia_patches.append(m.group("name"))

    prepare = function_body(text, "prepare")
    if not prepare:
        fail("prepare() not found")

    out = {
        "major": values["_major"],
        "minor": values["_minor"],
        "tagrel": values["_tagrel"],
        "pkgrel": values["pkgrel"],
        "version": f"{values['_major']}.{values['_minor']}",
        "srctag": f"cachyos-{values['_major']}.{values['_minor']}-{values['_tagrel']}",
        "cachyos_nvidia_version": values["_nv_ver"],
        "knobs": knobs,
        "kernel_patches": kernel_patches,
        "nvidia_patches": nvidia_patches,
        "prepare_sha256": hashlib.sha256(prepare.encode()).hexdigest(),
        "pkgbuild_sha256": hashlib.sha256(text.encode()).hexdigest(),
    }
    json.dump(out, sys.stdout, indent=2, sort_keys=True)
    print()


if __name__ == "__main__":
    main()

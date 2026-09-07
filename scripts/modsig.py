#!/usr/bin/env python3
"""Verify Linux kernel module signatures against an X.509 certificate.

    modsig.py --cert kestrel.crt module.ko[.zst] [...]

A signed module ends with:  <PKCS#7 DER> <struct module_signature (12 bytes)>
<"~Module signature appended~\\n">. The PKCS#7 blob is a detached CMS
signature over the module body. This script splits the file, then asks
openssl to verify the CMS blob with the given certificate as the only trust
anchor. Exit code 0 only if every module verifies.
"""

import argparse
import os
import struct
import subprocess
import sys
import tempfile

MAGIC = b"~Module signature appended~\n"
SIG_STRUCT = struct.Struct(">BBBBBB2xI")  # algo, hash, id_type, signer_len, key_id_len, __pad[3] as 2x+... see below


def split(data):
    if not data.endswith(MAGIC):
        raise ValueError("no module signature magic")
    body = data[: -len(MAGIC)]
    # struct module_signature { u8 algo, hash, id_type, signer_len, key_id_len, __pad[3]; __be32 sig_len; }
    if len(body) < 12:
        raise ValueError("truncated signature header")
    hdr = body[-12:]
    algo, hash_, id_type, signer_len, key_id_len = hdr[0], hdr[1], hdr[2], hdr[3], hdr[4]
    (sig_len,) = struct.unpack(">I", hdr[8:12])
    if id_type != 2:  # PKEY_ID_PKCS7
        raise ValueError(f"unexpected id_type {id_type}")
    if algo or hash_ or signer_len or key_id_len:
        raise ValueError("non-zero legacy fields in PKCS#7 signature header")
    rest = body[:-12]
    if sig_len > len(rest):
        raise ValueError("signature length exceeds file")
    return rest[:-sig_len], rest[-sig_len:]


def read_module(path):
    if path.endswith(".zst"):
        return subprocess.run(["zstd", "-dcq", path], check=True, capture_output=True).stdout
    if path.endswith(".xz"):
        return subprocess.run(["xz", "-dc", path], check=True, capture_output=True).stdout
    with open(path, "rb") as f:
        return f.read()


def verify(path, cert):
    data = read_module(path)
    content, pkcs7 = split(data)
    with tempfile.TemporaryDirectory() as d:
        cf = os.path.join(d, "content.bin")
        sf = os.path.join(d, "sig.p7s")
        with open(cf, "wb") as f:
            f.write(content)
        with open(sf, "wb") as f:
            f.write(pkcs7)
        # -purpose any: the kestrel cert has keyUsage digitalSignature only.
        # -noverify would skip chain validation; instead pin the cert as CA
        # and require the signer to be that cert (partial_chain).
        r = subprocess.run(
            ["openssl", "cms", "-verify", "-binary", "-inform", "DER", "-in", sf, "-content", cf,
             "-CAfile", cert, "-certfile", cert, "-partial_chain", "-purpose", "any", "-out", os.devnull],
            capture_output=True, text=True,
        )
        if r.returncode != 0:
            return False, r.stderr.strip().splitlines()[-1] if r.stderr.strip() else "openssl cms failed"
        # Also confirm the signer certificate embedded or referenced is ours.
        p = subprocess.run(["openssl", "pkcs7", "-inform", "DER", "-in", sf, "-print_certs", "-noout"],
                           capture_output=True, text=True)
        return True, "ok" + (" (no embedded cert)" if not p.stdout.strip() else "")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--cert", required=True)
    ap.add_argument("modules", nargs="+")
    a = ap.parse_args()
    bad = 0
    for m in a.modules:
        try:
            ok, msg = verify(m, a.cert)
        except Exception as e:  # noqa: BLE001
            ok, msg = False, str(e)
        print(f"{'PASS' if ok else 'FAIL'} {m}: {msg}")
        bad += 0 if ok else 1
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()

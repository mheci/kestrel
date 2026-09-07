#!/usr/bin/env bash
# Boot a bootc-image-builder qcow2 under UEFI and check the kestrel kernel
# came up through the real bootloader path.
#
#   boot-disk.sh DISK.qcow2 OUT_DIR
#
# Talks to the guest over the serial console: waits for the login prompt,
# logs in as the user bib created (kestrel/kestrel), runs a few commands and
# reads their output back. Writes OUT_DIR/disk-console.log and
# OUT_DIR/disk-result.txt.

source "$(dirname "${BASH_SOURCE[0]}")/../scripts/lib.sh"
need qemu-system-x86_64 python3 jq

disk=$(readlink -f "${1:?}")
out=$(readlink -f "${2:?}")
mkdir -p "$out"
kver=$(jget "$out/manifest.json" .kver)
nvver=$(jget "$out/manifest.json" .nvidia.version)

ovmf_code=$(ls /usr/share/OVMF/OVMF_CODE_4M.fd /usr/share/OVMF/OVMF_CODE.fd 2>/dev/null | head -1)
ovmf_vars=$(ls /usr/share/OVMF/OVMF_VARS_4M.fd /usr/share/OVMF/OVMF_VARS.fd 2>/dev/null | head -1)
[[ -n $ovmf_code && -n $ovmf_vars ]] || die "OVMF firmware not found"
vars=$(mktemp); cp "$ovmf_vars" "$vars"
accel=tcg; cpu=max
[[ -w /dev/kvm ]] && { accel=kvm; cpu=host; }

python3 - "$disk" "$ovmf_code" "$vars" "$accel" "$cpu" "$out" "$kver" "$nvver" <<'EOF'
import os, re, subprocess, sys, time, json
disk, code, vars_, accel, cpu, out, kver, nvver = sys.argv[1:9]
timeout = 1500 if accel == "tcg" else 600
cmd = ["qemu-system-x86_64", "-accel", accel, "-cpu", cpu, "-smp", "2", "-m", "3072", "-machine", "q35",
       "-drive", f"if=pflash,format=raw,readonly=on,file={code}", "-drive", f"if=pflash,format=raw,file={vars_}",
       "-drive", f"file={disk},format=qcow2,if=virtio", "-device", "virtio-rng-pci",
       "-netdev", "user,id=n0", "-device", "virtio-net-pci,netdev=n0",
       "-nographic", "-serial", "stdio", "-monitor", "none", "-display", "none", "-no-reboot"]
p = subprocess.Popen(cmd, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, bufsize=0)
log = open(os.path.join(out, "disk-console.log"), "wb")
buf = b""
start = time.time()

def read_until(patterns, limit):
    global buf
    end = time.time() + limit
    while time.time() < end:
        chunk = os.read(p.stdout.fileno(), 4096) if p.poll() is None else b""
        if chunk:
            log.write(chunk); log.flush(); buf += chunk
            for pat in patterns:
                if re.search(pat, buf[-8000:]):
                    return pat
        else:
            if p.poll() is not None:
                return None
            time.sleep(0.2)
    return None

def send(s):
    p.stdin.write(s.encode() + b"\n"); p.stdin.flush()

def run(cmdline, marker):
    global buf
    buf = b""
    send(f"{cmdline}; echo {marker}-$?")
    got = read_until([marker.encode() + rb"-(\d+)"], 120)
    text = buf.decode(errors="replace")
    m = re.search(marker + r"-(\d+)", text)
    rc = int(m.group(1)) if m else -1
    body = text.split("\n", 1)[1] if "\n" in text else text
    body = body[: body.rfind(marker)] if marker in body else body
    return rc, body.strip()

results = {}
if read_until([rb"login: "], timeout) is None:
    results["login_prompt"] = "not reached"
    p.kill(); json.dump(results, open(os.path.join(out, "disk-result.txt"), "w"), indent=1); sys.exit(1)
results["boot_seconds"] = round(time.time() - start, 1)
send("kestrel")
read_until([rb"Password: "], 60)
send("kestrel")
if read_until([rb"\$ ", rb"# "], 60) is None:
    results["shell"] = "no prompt after login"
    p.kill(); json.dump(results, open(os.path.join(out, "disk-result.txt"), "w"), indent=1); sys.exit(1)
checks = {
    "uname": "uname -r",
    "selinux": "getenforce",
    "sig_enforce": "cat /sys/module/module/parameters/sig_enforce",
    "bootc_status": "sudo bootc status --format json | head -c 2000",
    "kestrel_rpms": "rpm -q kestrel-kernel kestrel-nvidia-kmod nvidia-driver",
    "nvidia_modprobe": "sudo modprobe nvidia 2>&1; echo rc=$?",
    "sig_failures": "sudo dmesg | grep -c -i -E 'module verification failed|Loading of unsigned|key was rejected' ",
    "efi_boot": "test -d /sys/firmware/efi && echo uefi || echo bios",
    "ostree_root": "findmnt -n -o SOURCE,FSTYPE / ",
    "cmdline": "cat /proc/cmdline",
}
for k, c in checks.items():
    rc, body = run(c, f"KSTRL{k.upper()}")
    results[k] = {"rc": rc, "out": body[-1500:]}
json.dump(results, open(os.path.join(out, "disk-result.txt"), "w"), indent=1)
send("sudo systemctl poweroff")
read_until([rb"reboot: Power down", rb"Power down"], 120)
p.kill()
ok = True
def check(name, cond, detail):
    global ok
    print(("PASS " if cond else "FAIL ") + name + ": " + detail)
    ok = ok and cond
check("login prompt reached", True, f"{results['boot_seconds']}s ({accel})")
check("uname -r", results["uname"]["out"].strip().endswith(kver), results["uname"]["out"].strip())
check("SELinux enforcing", "Enforcing" in results["selinux"]["out"], results["selinux"]["out"].strip())
check("sig_enforce", results["sig_enforce"]["out"].strip().endswith("Y"), results["sig_enforce"]["out"].strip())
check("kestrel rpms present", results["kestrel_rpms"]["rc"] == 0, results["kestrel_rpms"]["out"].replace("\n", " "))
nv = results["nvidia_modprobe"]["out"]
check("nvidia.ko verified (no GPU in VM)", ("rc=0" in nv) or ("No such device" in nv) or ("Operation not permitted" in nv) and "key" not in nv.lower(), nv.strip().replace("\n", " ")[:200])
check("no signature failures", results["sig_failures"]["out"].strip().endswith("0"), results["sig_failures"]["out"].strip())
check("UEFI boot", "uefi" in results["efi_boot"]["out"], results["efi_boot"]["out"].strip())
check("bootc status", results["bootc_status"]["rc"] == 0 and "booted" in results["bootc_status"]["out"], results["bootc_status"]["out"][:120].replace("\n", " "))
sys.exit(0 if ok else 1)
EOF

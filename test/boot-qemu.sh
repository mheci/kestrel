#!/usr/bin/env bash
# Boot the reference image's kernel and initramfs in QEMU with the image's
# root filesystem, then run checks inside the guest.
#
#   boot-qemu.sh REFERENCE_IMAGE OUT_DIR
#
# How: export the container rootfs to a raw ext4 disk with a virtio-blk
# device, boot the kestrel vmlinuz + the initramfs dracut built inside the
# image via direct kernel boot (-kernel/-initrd), root=/dev/vda. The kernel
# command line carries module.sig_enforce=1 and selinux=1 enforcing=0 (the
# container filesystem has no labels, so enforcing would block the check
# script itself; the kernel proves SELinux is active by mounting selinuxfs).
#
# Checks run from a systemd unit inside the guest and land in
# /var/kestrel-boot/result.json on the disk, which the host reads back.
# Serial console output goes to OUT_DIR/boot-console.log.
#
# KVM is used when /dev/kvm is writable, else TCG.

# shellcheck disable=SC2015  # "test && ok || bad" is intended; ok never fails
source "$(dirname "${BASH_SOURCE[0]}")/../scripts/lib.sh"
need podman qemu-system-x86_64 mkfs.ext4 debugfs jq truncate

image=${1:?usage: boot-qemu.sh IMAGE OUT_DIR}
out=$(readlink -f "${2:?usage: boot-qemu.sh IMAGE OUT_DIR}")
mkdir -p "$out"
manifest="$out/manifest.json"
kver=$(jget "$manifest" .kver)

work=$(mktemp -d "${TMPDIR:-/tmp}/kestrel-boot.XXXXXX")
trap 'rm -rf "$work"' EXIT

# Run as root: ownership inside the exported tree must survive into the
# ext4 image (root-owned /etc, setuid bits), and root podman is where the
# workflow built the image.
[[ $(id -u) -eq 0 ]] || die "run as root (sudo -E)"

group "Export rootfs from $image"
cid=$(podman create "$image" /bin/true)
mkdir -p "$work/rootfs"
podman export "$cid" | tar -x -C "$work/rootfs" -f -
podman rm -f "$cid" >/dev/null
# The image's kernel and the initramfs its dracut built.
[[ -f $work/rootfs/usr/lib/modules/$kver/vmlinuz && -f $work/rootfs/usr/lib/modules/$kver/initramfs.img ]] || die "kernel or initramfs missing in image"
cp "$work/rootfs/usr/lib/modules/$kver/vmlinuz" "$work/vmlinuz"
cp "$work/rootfs/usr/lib/modules/$kver/initramfs.img" "$work/initrd"
log "vmlinuz $(stat -c %s "$work/vmlinuz") bytes, initramfs $(stat -c %s "$work/initrd") bytes"
endgroup

group "Guest check unit"
mkdir -p "$work/rootfs/var/kestrel-boot" "$work/rootfs/etc/systemd/system/multi-user.target.wants"
# The guest writes one plain file per fact under /var/kestrel-boot; the host
# reads them back with debugfs and builds the JSON. No quoting of dmesg
# output inside the guest that way.
cat >"$work/rootfs/usr/libexec/kestrel-boot-check" <<'EOF'
#!/bin/bash
# Runs once inside the guest; writes facts to /var/kestrel-boot then powers off.
set -u
d=/var/kestrel-boot
f() { printf '%s\n' "$2" >"$d/$1"; }
f uname_r "$(uname -r)"
f selinux_fs "$(test -d /sys/fs/selinux && echo mounted || echo missing)"
f selinux_enforce "$(cat /sys/fs/selinux/enforce 2>/dev/null || echo n/a)"
f sig_enforce "$(cat /sys/module/module/parameters/sig_enforce 2>/dev/null || echo n/a)"
# A signed in-tree module with no hardware dependency.
if modprobe loop 2>"$d/loop.err"; then f loop_module ok; else f loop_module "fail: $(cat "$d/loop.err")"; fi
# NVIDIA: dependency resolution through modprobe (no GPU in QEMU, so
# nvidia.ko itself refuses to init; the point is that the module and its
# whole chain are found, verified and get past the signature checks).
if modprobe --dry-run --show-depends nvidia-drm >"$d/nvidia_depends.txt" 2>&1; then f nvidia_depends ok; else f nvidia_depends "fail: $(cat "$d/nvidia_depends.txt")"; fi
modprobe nvidia 2>"$d/nvidia_modprobe_err"; f nvidia_modprobe_rc "$?"
dmesg | grep -i -E 'nvidia|NVRM' | tail -20 >"$d/nvidia_dmesg" || true
f signature_failures_in_dmesg "$(dmesg | grep -i -c -E 'module verification failed|Loading of unsigned module|PKCS#7 signature not signed|signature.*invalid' || true)"
f tainted "$(cat /proc/sys/kernel/tainted)"
f cmdline "$(cat /proc/cmdline)"
f btf "$(test -f /sys/kernel/btf/vmlinux && echo present || echo missing)"
f cpu "$(grep -q -w avx2 /proc/cpuinfo && echo v3-capable || echo no-avx2)"
dmesg >"$d/dmesg.txt" 2>/dev/null || true
f finished yes
echo "KESTREL-BOOT-CHECK-DONE"
sync
systemctl poweroff
EOF
chmod +x "$work/rootfs/usr/libexec/kestrel-boot-check"
cat >"$work/rootfs/etc/systemd/system/kestrel-boot-check.service" <<'EOF'
[Unit]
Description=kestrel boot check
After=basic.target systemd-modules-load.service systemd-udev-trigger.service
[Service]
Type=oneshot
ExecStart=/usr/libexec/kestrel-boot-check
StandardOutput=journal+console
StandardError=journal+console
[Install]
WantedBy=multi-user.target
EOF
ln -sf ../kestrel-boot-check.service "$work/rootfs/etc/systemd/system/multi-user.target.wants/kestrel-boot-check.service"
# A plain container rootfs has no fstab, machine-id or root password; give it
# what a first boot needs and nothing more.
: >"$work/rootfs/etc/machine-id"
printf '/dev/vda / ext4 defaults 0 0\n' >"$work/rootfs/etc/fstab"
# Getty on serial for debugging in the console log; no login needed.
mkdir -p "$work/rootfs/etc/systemd/system/serial-getty@ttyS0.service.d"
# Do not let display managers or NetworkManager slow a headless boot.
for u in sddm gdm plasma-kwin_wayland NetworkManager-wait-online firewalld rpm-ostreed bootc-fetch-apply-updates.timer; do
  ln -sf /dev/null "$work/rootfs/etc/systemd/system/$u.service" 2>/dev/null || true
done
endgroup

group "Disk image"
size=$(du -sm "$work/rootfs" | cut -f1)
disk="$work/root.img"
truncate -s "$(( size + 1500 ))M" "$disk"
mkfs.ext4 -q -F -L kestrelroot -d "$work/rootfs" "$disk"
rm -rf "$work/rootfs"
log "root disk $(stat -c %s "$disk" | numfmt --to=iec)"
endgroup

group "QEMU boot"
accel=tcg; cpu=max
if [[ -w /dev/kvm ]]; then accel=kvm; cpu=host; fi
console="$out/boot-console.log"
: >"$console"
timeout_s=${KESTREL_BOOT_TIMEOUT:-900}
[[ $accel == tcg ]] && timeout_s=$(( timeout_s * 2 ))
set +e
timeout --kill-after=20 "$timeout_s" qemu-system-x86_64 \
  -accel "$accel" -cpu "$cpu" -smp 2 -m 3072 -machine q35 -no-reboot \
  -kernel "$work/vmlinuz" -initrd "$work/initrd" \
  -append "root=/dev/vda rw rootfstype=ext4 console=ttyS0,115200n8 systemd.journald.forward_to_console=0 module.sig_enforce=1 selinux=1 enforcing=0 systemd.unit=multi-user.target rd.driver.blacklist=nouveau modprobe.blacklist=nouveau nvidia-drm.modeset=1 loglevel=4 printk.devkmsg=on" \
  -drive "file=$disk,format=raw,if=virtio,cache=unsafe" \
  -device virtio-rng-pci -netdev user,id=n0 -device virtio-net-pci,netdev=n0 \
  -serial "file:$console" -monitor none -display none
qrc=$?
set -e
log "qemu exited $qrc ($accel)"
endgroup

group "Result"
res="$out/boot-result.json"
# Read the facts back from the ext4 image without mounting (debugfs).
fact() { debugfs -R "cat /var/kestrel-boot/$1" "$disk" 2>/dev/null || true; }
if [[ $(fact finished) != yes ]]; then
  log "guest wrote no result; last console lines:"; tail -60 "$console" >&2
  die "guest did not finish the check unit"
fi
fact dmesg.txt >"$out/boot-dmesg.log"
jq -n \
  --arg uname_r "$(fact uname_r)" --arg selinux_fs "$(fact selinux_fs)" --arg selinux_enforce "$(fact selinux_enforce)" \
  --arg sig_enforce "$(fact sig_enforce)" --arg loop_module "$(fact loop_module)" --arg nvidia_depends "$(fact nvidia_depends)" \
  --arg nvidia_modprobe_rc "$(fact nvidia_modprobe_rc)" --arg nvidia_modprobe_err "$(fact nvidia_modprobe_err)" \
  --arg nvidia_dmesg "$(fact nvidia_dmesg)" --arg signature_failures_in_dmesg "$(fact signature_failures_in_dmesg)" \
  --arg tainted "$(fact tainted)" --arg cmdline "$(fact cmdline)" --arg btf "$(fact btf)" --arg cpu "$(fact cpu)" \
  '$ARGS.named' >"$res"
cat "$res"
pass=0; fail=0
ok() { pass=$((pass+1)); printf 'PASS %s\n' "$*"; }
bad() { fail=$((fail+1)); printf 'FAIL %s\n' "$*"; }
[[ $(jq -r .uname_r "$res") == "$kver" ]] && ok "uname -r is $kver" || bad "uname -r $(jq -r .uname_r "$res")"
[[ $(jq -r .selinux_fs "$res") == mounted ]] && ok "selinuxfs mounted (SELinux LSM active)" || bad "selinux not active"
[[ $(jq -r .sig_enforce "$res") == Y ]] && ok "module.sig_enforce=1 in effect" || bad "sig_enforce $(jq -r .sig_enforce "$res")"
[[ $(jq -r .loop_module "$res") == ok ]] && ok "signed in-tree module loads under sig_enforce" || bad "loop: $(jq -r .loop_module "$res")"
[[ $(jq -r .nvidia_depends "$res") == ok ]] && ok "nvidia-drm dependency chain resolves" || bad "nvidia depends: $(jq -r .nvidia_depends "$res")"
[[ $(jq -r .signature_failures_in_dmesg "$res") == 0 ]] && ok "no signature failures in dmesg" || bad "signature failures in dmesg"
[[ $(jq -r .btf "$res") == present ]] && ok "BTF exposed at /sys/kernel/btf/vmlinux" || bad "no BTF"
# nvidia.ko with no GPU: modprobe returns non-zero ("No such device") after the
# module was verified and initialised far enough to probe. A signature or
# symbol problem gives a different error, so distinguish them.
nverr=$(jq -r .nvidia_modprobe_err "$res")
nvrc=$(jq -r .nvidia_modprobe_rc "$res")
if [[ $nvrc == 0 ]]; then ok "nvidia.ko loaded (rc 0)"
elif grep -q -i -E 'No such device|Operation not permitted|Input/output error' <<<"$nverr" && ! grep -q -i -E 'key was rejected|Required key not available|Unknown symbol|Invalid module format|Exec format' <<<"$nverr"; then
  ok "nvidia.ko verified and probed, no GPU present (rc $nvrc: ${nverr})"
else bad "nvidia.ko: rc $nvrc: $nverr"; fi
grep -q 'KESTREL-BOOT-CHECK-DONE' "$console" && ok "guest reached the check unit and powered off" || bad "check unit did not finish"
printf '\nboot verification: %d passed, %d failed (accel=%s)\n' "$pass" "$fail" "$accel"
endgroup
[[ $fail -eq 0 ]]

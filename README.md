# kestrel

A continuously built OCI artifact that carries the CachyOS kernel and the
NVIDIA open GPU kernel modules built for it, packaged for Fedora bootc images
(Bazzite, Bluefin, Aurora, Ryven and anything else based on ostree/bootc).

    ghcr.io/mheci/kestrel:stable   linux-cachyos       (7.x, ThinLTO, x86-64-v3)
    ghcr.io/mheci/kestrel:lts      linux-cachyos-lts   (6.18.x, ThinLTO, x86-64-v3)

Nothing here is meant to be booted directly. The image is a payload you copy
into your own image build.

## Use it

```Dockerfile
FROM ghcr.io/ublue-os/kinoite-main:latest

# NVIDIA userspace from Terra (or RPM Fusion) at the version kestrel carries,
# in one transaction with the kestrel kernel and kmod. The version is in the
# kestrel manifest; the installer refuses a mismatch.
COPY --from=ghcr.io/mheci/kestrel:stable / /tmp/kestrel
RUN rpm --import /tmp/kestrel/usr/share/kestrel/RPM-GPG-KEY-kestrel \
 && dnf5 -y install --enablerepo=terra-nvidia --exclude=akmod-nvidia,kmod-nvidia \
      nvidia-driver nvidia-driver-libs nvidia-kmod-common nvidia-modprobe nvidia-driver-selinux \
      /tmp/kestrel/rpms/kestrel-kernel-[0-9]*.rpm /tmp/kestrel/rpms/kestrel-nvidia-kmod-*.rpm \
 && /tmp/kestrel/usr/libexec/kestrel-install \
 && rm -rf /tmp/kestrel
```

Without NVIDIA userspace, `kestrel-install` alone is enough; it installs the
RPMs itself.

`kestrel-install` removes the Fedora kernel packages, installs whichever of
`kestrel-kernel`, `kestrel-kernel-devel` and `kestrel-nvidia-kmod` are not in
place yet (with rpm, no scriptlets), runs depmod, writes a dnf `excludepkgs`
guard so a later `dnf install` cannot pull the Fedora kernel back, generates
the initramfs with the image's own dracut configuration plus the ostree and
bootc modules (which only enter when asked, as rpm-ostree does), and checks that
exactly one kernel remains under `/usr/lib/modules` with nothing in `/boot`.
`kestrel-install --help` lists the switches (`--no-initramfs`,
`--no-dnf-guard`, `--no-devel`).

If you would rather do it yourself, the RPMs are plain packages under
`/rpms/` with no scriptlets. `kestrel-nvidia-kmod` provides
`nvidia-kmod = 3:<version>` and `kmod-nvidia`, so Terra's `nvidia-kmod-common`
and RPM Fusion's `xorg-x11-drv-nvidia` resolve against it.

Kernel arguments are yours to set. The reference image used in CI adds
`rd.driver.blacklist=nouveau modprobe.blacklist=nouveau nvidia-drm.modeset=1
module.sig_enforce=1` through `/usr/lib/bootc/kargs.d/`.

## What is inside

| Path | Content |
| --- | --- |
| `/rpms/kestrel-kernel-*.rpm` | `/usr/lib/modules/<kver>/{vmlinuz,System.map,config,kernel/…}`; provides `kernel`, `kernel-core`, `kernel-modules*`, `kernel-uname-r` |
| `/rpms/kestrel-kernel-devel-*.rpm` | `/usr/src/kernels/<kver>` plus the `build` symlink; provides `kernel-devel-uname-r` |
| `/rpms/kestrel-nvidia-kmod-*.rpm` | `/usr/lib/modules/<kver>/extra/nvidia/{nvidia,nvidia-modeset,nvidia-drm,nvidia-uvm,nvidia-peermem}.ko.zst` |
| `/usr/libexec/kestrel-install` | the installer described above |
| `/usr/share/kestrel/manifest.json` | every input pinned by hash, the config delta from CachyOS, toolchain versions, signature fingerprints |
| `/usr/share/kestrel/kestrel.crt` | X.509 certificate that signed the modules and `vmlinuz` |
| `/usr/share/kestrel/RPM-GPG-KEY-kestrel` | OpenPGP key that signed the RPMs |
| `/usr/share/kestrel/LICENSES/` | GPL-2.0 (kernel), MIT and GPL-2.0 (NVIDIA modules), Apache-2.0 (kestrel) |

`kver` looks like `7.2.3-2.cachyos.fc44.x86_64` or
`6.18.48-2.cachyos.lts.fc44.x86_64`: CachyOS version and tag release, variant,
Fedora release, arch. This is what `uname -r` prints, and it is also
`%{VERSION}-%{RELEASE}.%{ARCH}` of the `kestrel-kernel` RPM, the same shape
Fedora's kernel has, so tooling that derives `kernel-uname-r` from the RPM
works unchanged.

## Tags

| Tag | Meaning |
| --- | --- |
| `stable`, `lts` | floating, the newest green build of the channel |
| `stable-7.2.3-2-610.57.04` | immutable pin: kernel tag and NVIDIA version |
| `stable-7.2.3-2.cachyos.fc44.x86_64` | immutable pin: kver |
| `stable-7.2.3-2` | last build for that kernel tag (moves when NVIDIA changes) |
| `stable-fc44` | last build for that Fedora release |

Images are signed with cosign (keyless, GitHub OIDC):

    cosign verify ghcr.io/mheci/kestrel:stable \
      --certificate-identity-regexp '^https://github.com/mheci/kestrel/' \
      --certificate-oidc-issuer https://token.actions.githubusercontent.com

## How the kernel is built

Every six hours the poll workflow reads three upstreams: the CachyOS PKGBUILD
for the variant (pinned to the commit that last touched it), the Fedora
release behind `ghcr.io/ublue-os/kinoite-main:latest`, and the `nvidia-driver`
version in Terra's nvidia repository for that release. A hash over those
inputs and the recipe files in this repository (channels, specs, scripts,
builder and artifact Containerfiles, installer) is the build id. When it
differs from the label on the published image, a channel build starts. Test
and workflow changes do not enter the hash, so tightening a check never
costs a rebuild.

The build runs on free GitHub runners inside a Fedora container with Fedora's
own clang and lld, so modules a consumer compiles later against
`kestrel-kernel-devel` use the same compiler. A full kernel takes longer than
one six hour job, so the compile is split into time-boxed stages that share a
ccache; a point release usually finishes in the first stage.

The configuration is the CachyOS config for the variant, with the PKGBUILD's
knobs applied the same way makepkg would (BORE, 1000 Hz, full preemption,
NO_HZ_FULL, THP always, -O3), then a small delta for Fedora bootc consumers.
The delta is listed in `manifest.json` under
`kernel.config_delta_from_cachyos`; today it is:

- `CONFIG_LSM` gains `selinux` and `CONFIG_DEFAULT_SECURITY_SELINUX=y`
- `CONFIG_X86_64_VERSION=3` (CachyOS's own repo build for the v3 package does the same)
- `CONFIG_LTO_CLANG_THIN=y` on both channels (CachyOS ships the LTS variant as ThinLTO too)
- `CONFIG_MODULE_SIG_KEY` points at the persistent kestrel RSA-4096 key instead of a per-build ECDSA key
- `CONFIG_DEBUG_INFO_COMPRESSED_ZSTD=y`, a build-time size measure; shipped files are identical
- `CONFIG_RUST=n`, which Kconfig forces anyway with BTF plus LTO
- no AutoFDO or Propeller, because CachyOS does not publish the profile

Unlike CachyOS's own CI builds, the kernel is compiled with -O3 and full
DWARF 5 debug info, then stripped, so BTF and ORC are complete.

The NVIDIA modules come from NVIDIA's `NVIDIA-kernel-module-source` tarball
for the exact version Terra ships. CachyOS's nvidia patches for the kernel
major are applied when they apply; any that do not are recorded in the
manifest as skipped rather than failing the build. Modules are built with the
kernel's clang, signed with the kestrel key and zstd compressed.

## Verification before publish

A build is published only after:

1. static checks on the RPMs: one kernel directory, `vmlinuz` Authenticode
   signature verifies against `kestrel.crt`, every module is zstd and signed,
   NVIDIA `vermagic` equals kver, depmod resolves with nothing missing,
   provides and requires are what Fedora tooling expects, RPM OpenPGP
   signatures verify;
2. a reference image (`kinoite-main` plus Terra NVIDIA userspace plus
   `kestrel-install`) passes `bootc container lint`;
3. that image boots in QEMU with `module.sig_enforce=1`, comes up as the
   kestrel kernel with SELinux active, loads a signed in-tree module, resolves
   the nvidia-drm dependency chain, and `nvidia.ko` gets as far as "no such
   device" without a signature or symbol error.

Every night a separate workflow builds a qcow2 from the reference image with
bootc-image-builder and boots it through UEFI, GRUB, ostree and the initramfs
with SELinux enforcing.

A failed build leaves the floating tag where it was and opens or updates one
GitHub issue per channel (labels `kestrel-failure`, `channel:<name>`); the
issue closes itself when the channel publishes again. A kernel is never
published without its NVIDIA modules.

Retention keeps the current build plus the two previous builds per channel.

## Keys

| Purpose | Fingerprint |
| --- | --- |
| Module and vmlinuz signing certificate (`keys/kestrel.crt`, SHA-256) | `51:70:A2:D8:50:72:15:BE:CA:68:A0:C4:93:E4:BA:55:16:9E:0B:C8:88:E5:FE:B9:12:AC:CE:CE:E7:2C:45:D2` |
| RPM OpenPGP key (`keys/RPM-GPG-KEY-kestrel`) | `C147 4B73 7BE5 E37F 607F  9570 EE57 9B31 A78D B5C4` |

The certificate is compiled into the kernel's builtin trusted keyring, so
`module.sig_enforce=1` accepts kestrel modules and nothing else. `vmlinuz`
is signed with the same key, so a machine with Secure Boot on boots it once
the certificate is enrolled as a MOK. Every installed image carries the DER
form at `/usr/share/kestrel/kestrel.der` (also `keys/kestrel.der` here):

    sudo mokutil --import /usr/share/kestrel/kestrel.der   # then reboot and confirm in the MOK manager

Private keys live only in GitHub Actions secrets.

## Repository map

    channels/           one .env per channel: CachyOS variant and kver suffix
    scripts/resolve.sh  upstream inputs -> want.json (pinned)
    scripts/kernel-prepare.sh, kernel-build.sh, nvidia-build.sh, package.sh
    rpm/                the two spec files
    containers/         builder, artifact and reference Containerfiles, kestrel-install
    test/               verify-static.sh, boot-qemu.sh, boot-disk.sh
    .github/            poll, channel and nightly disk workflows

## License

Apache-2.0 for everything in this repository. The kernel is GPL-2.0-only, the
NVIDIA open kernel modules are MIT and GPL-2.0; their licence texts ship in
the artifact.

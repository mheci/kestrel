# Builder for kestrel kernels. Fedora N with Fedora's own LLVM, so modules
# a consumer compiles later with dnf's clang against kestrel-kernel-devel
# use the same compiler the kernel was built with.
ARG FEDORA_RELEASE=44
FROM quay.io/fedora/fedora:${FEDORA_RELEASE}
RUN dnf -y --setopt=install_weak_deps=False install \
      clang lld llvm ccache dwarves \
      elfutils-libelf-devel openssl openssl-devel \
      bc bison flex perl-core perl-interpreter python3 \
      zstd xz tar gzip bzip2 patch gnupg2 kmod sbsigntools rpm-build rpm-sign binutils \
      make gcc git file findutils diffutils cpio which hostname jq curl \
      zlib-devel ncurses-devel util-linux-core coreutils procps-ng \
    && dnf clean all \
    && rm -rf /var/cache/dnf /var/cache/libdnf5
ENV LANG=C.UTF-8
WORKDIR /work

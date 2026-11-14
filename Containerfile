# atomic-linux: a generic Fedora Atomic (bootc) desktop/host base image.
#
# It is meant to be derived from, not edited: a downstream repository holds
# a small Containerfile starting with
#   FROM ghcr.io/cgwalters-forge/atomic-linux@sha256:...
# plus its own configuration. See README.md.
#
# The build follows the Universal Blue finpilot template's multi-stage layout
# (https://github.com/projectbluefin/finpilot): a scratch "ctx" stage gathers
# local build scripts and files plus OCI context images, and RUN steps bind
# mount it at /ctx.

# OCI context images, pinned by digest (Dependabot proposes bumps).
FROM ghcr.io/projectbluefin/common:latest@sha256:df2fa93dac84cda91d568bd694e5051abbbdba37bf3d54a6cc15cdc80e645e2c AS common
FROM ghcr.io/ublue-os/brew:latest@sha256:c201bc801e4828849e8e36c4adcb5c0f38d35ac3ff9546a0ecab0fd2beabf51f AS brew

FROM scratch AS ctx
COPY build /build
COPY custom /custom
# @projectbluefin/common is carried in the context for scripts that want
# Bluefin's shared desktop files; 10-build.sh does not overlay it today.
COPY --from=common /system_files /oci/common
COPY --from=brew /system_files /oci/brew

# Base image: Fedora's official Silverblue (GNOME) bootc image. Alternatives
# with the same layout: quay.io/fedora-ostree-desktops/base-main (no desktop)
# or quay.io/centos-bootc/centos-bootc:stream10.
FROM quay.io/fedora-ostree-desktops/silverblue:44@sha256:6f18b1c32e1904c7019807ffbeb7cd066683d72b0504d046abcb07cbdf4c9fab

# Image identity, recorded in /usr/share/ublue-os/image-info.json. Derived
# images re-run /usr/libexec/atomic-linux/write-image-info with their own.
ARG IMAGE_NAME="atomic-linux"
ARG IMAGE_VENDOR="cgwalters-forge"
ARG IMAGE_REGISTRY="ghcr.io/cgwalters-forge"
ARG UBLUE_IMAGE_TAG="stable"
ARG BASE_IMAGE_NAME="silverblue"
ARG FEDORA_MAJOR_VERSION="44"

RUN --mount=type=bind,from=ctx,source=/,target=/ctx \
    --mount=type=tmpfs,dst=/boot \
    --mount=type=tmpfs,dst=/tmp \
    install -D -m 0755 /ctx/build/00-image-info.sh /usr/libexec/atomic-linux/write-image-info \
    && /usr/libexec/atomic-linux/write-image-info

# Keep the dnf cache during the build; clean-stage.sh restores the default.
RUN cp /etc/dnf/dnf.conf /etc/dnf/dnf.conf.tmp \
    && mv /etc/dnf/dnf.conf.tmp /etc/dnf/dnf.conf \
    && dnf5 config-manager setopt keepcache=1 install_weak_deps=0

RUN --mount=type=bind,from=ctx,source=/,target=/ctx \
    --mount=type=cache,dst=/var/cache/libdnf5 \
    --mount=type=cache,dst=/var/cache/rpm-ostree \
    --mount=type=tmpfs,dst=/boot \
    --mount=type=tmpfs,dst=/tmp \
    /ctx/build/10-build.sh

# Optional: a newer bootc, the composefs storage backend instead of ostree,
# and a transient /etc; see build/15-bootc.sh and the README. The defaults
# change nothing.
ARG BOOTC_SOURCE="fedora"
ARG STORAGE_BACKEND="ostree"
ARG ETC_MODE="persistent"
RUN --mount=type=bind,from=ctx,source=/,target=/ctx \
    --mount=type=cache,dst=/var/cache/libdnf5 \
    --mount=type=tmpfs,dst=/boot \
    --mount=type=tmpfs,dst=/tmp \
    BOOTC_SOURCE="${BOOTC_SOURCE}" STORAGE_BACKEND="${STORAGE_BACKEND}" ETC_MODE="${ETC_MODE}" /ctx/build/15-bootc.sh

# k3s is a separately pinned release, installed but not enabled; a derived
# image opts in with `systemctl enable k3s.service`.
RUN --mount=type=bind,from=ctx,source=/,target=/ctx \
    --mount=type=cache,dst=/var/cache/libdnf5 \
    --mount=type=tmpfs,dst=/boot \
    --mount=type=tmpfs,dst=/tmp \
    /ctx/build/20-k3s.sh

# /run is deliberately not a tmpfs here: clean-stage.sh must remove
# image-layer files such as /run/dnf so bootc lint's nonempty-run-tmp check
# passes.
RUN --mount=type=bind,from=ctx,source=/,target=/ctx \
    --mount=type=tmpfs,dst=/tmp \
    --mount=type=tmpfs,dst=/boot \
    /ctx/build/clean-stage.sh

# Writable /opt for runtime-installed software. An image that installs RPMs
# into /opt at build time should use `RUN rm /opt && mkdir /opt` instead.
RUN rm -rf /opt && ln -s /var/opt /opt

CMD ["/sbin/init"]

RUN bootc container lint --fatal-warnings

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
FROM ghcr.io/projectbluefin/common:latest@sha256:c09e135141f7736e3aaf879162ddebf85580fdbb6e90fb1a4ff42ed85ea1f208 AS common
FROM ghcr.io/ublue-os/brew:latest@sha256:393b567da078f0f0638450c388e229011dae06f94a90017cb7525b57d9faa46e AS brew

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
FROM quay.io/fedora-ostree-desktops/silverblue:44@sha256:0789a48f04bbd7308647879aa90155911822f879dae5d00b3eaa543c06e46d3e

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

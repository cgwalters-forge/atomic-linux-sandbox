export IMAGE_NAME := env("IMAGE_NAME", "atomic-linux")
export IMAGE_VENDOR := env("IMAGE_VENDOR", "cgwalters-forge")
export DEFAULT_TAG := env("DEFAULT_TAG", "stable")
export PODMAN := env("PODMAN", "podman")
export BCVK := env("BCVK", "bcvk")
export BCVK_CONNECTION := env("BCVK_CONNECTION", "qemu:///session")

# Read by build/15-bootc.sh: fedora, updates-testing or copr; ostree or
# composefs; persistent or transient.

export BOOTC_SOURCE := env("BOOTC_SOURCE", "fedora")
export STORAGE_BACKEND := env("STORAGE_BACKEND", "ostree")
export ETC_MODE := env("ETC_MODE", "persistent")

# The forge's shared workflow check (cgwalters-forge/actions, lint/README.md):
# actionlint, zizmor and the runner-label policy. FORGE_ACTIONS is a checkout
# of that repository beside this one. CONTAINER=podman runs it without docker.

forge_actions := env("FORGE_ACTIONS", "../actions")
local_image := "localhost/" + IMAGE_NAME

# Persistent test VMs; names are prefixed so they do not collide with yours.

vm_name := IMAGE_NAME + "-vm"
k3s_vm_name := IMAGE_NAME + "-k3s"

[private]
default:
    @just --list

# Build the image into rootless containers-storage as IMAGE_NAME:tag.
[group('Image')]
build tag=DEFAULT_TAG:
    #!/usr/bin/env bash
    set -euo pipefail
    fedora_version=$(sed -nE 's/^ARG FEDORA_MAJOR_VERSION="?([^"]+)"?/\1/p' Containerfile)
    if [[ -z "${fedora_version}" ]]; then
        echo "error: could not find ARG FEDORA_MAJOR_VERSION in Containerfile" >&2
        exit 1
    fi
    version="${fedora_version}.$(date -u +%Y%m%d)"
    revision=$(git rev-parse HEAD 2>/dev/null || true)
    source_url="https://github.com/${IMAGE_VENDOR}/${IMAGE_NAME}"
    ${PODMAN} build \
        --build-arg "IMAGE_NAME=${IMAGE_NAME}" \
        --build-arg "IMAGE_VENDOR=${IMAGE_VENDOR}" \
        --build-arg "UBLUE_IMAGE_TAG={{ tag }}" \
        --build-arg "BOOTC_SOURCE=${BOOTC_SOURCE}" \
        --build-arg "STORAGE_BACKEND=${STORAGE_BACKEND}" \
        --build-arg "ETC_MODE=${ETC_MODE}" \
        --label "org.opencontainers.image.title=${IMAGE_NAME}" \
        --label "org.opencontainers.image.version=${version}" \
        --label "org.opencontainers.image.description=Generic Fedora Atomic bootc desktop/host base image" \
        --label "org.opencontainers.image.source=${source_url}" \
        --label "org.opencontainers.image.url=${source_url}" \
        --label "org.opencontainers.image.revision=${revision}" \
        --label "org.opencontainers.image.licenses=Apache-2.0" \
        --label "org.opencontainers.image.created=$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        --label "containers.bootc=1" \
        --pull=newer \
        --tag "${IMAGE_NAME}:{{ tag }}" \
        .

# Composefs-native variant; needs bootc 1.17 (updates-testing, or copr for main).
[group('Image')]
build-composefs tag="composefs" source="updates-testing":
    BOOTC_SOURCE={{ source }} STORAGE_BACKEND=composefs {{ just_executable() }} --justfile "{{ justfile() }}" build {{ tag }}

# Test variant with a transient /etc and an audit watch on it (ostree backend).
[group('Image')]
build-transient-etc tag="transient-etc":
    ETC_MODE=transient {{ just_executable() }} --justfile "{{ justfile() }}" build {{ tag }}

# ShellCheck over build scripts, host helpers and tests.
[group('Quality')]
lint:
    shellcheck build/*.sh custom/system/usr/libexec/k3s-* tests/*.sh tests/kubevirt/*.sh

# Containerfile lint (pulls the hadolint image).
[group('Quality')]
hadolint:
    ${PODMAN} run --rm -i -v "$PWD/.hadolint.yaml:/.config/hadolint.yaml:ro,Z" docker.io/hadolint/hadolint:v2.12.0 < Containerfile

# Justfile formatting.
[group('Quality')]
fmt-check:
    just --unstable --fmt --check -f Justfile

# Workflow lint, as CI runs it.
[group('Quality')]
lint-workflows:
    {{ just_executable() }} --justfile "{{ forge_actions }}/lint/Justfile" --working-directory . check

# Remove generated local artifacts.
[group('Utility')]
clean:
    rm -rf output

# Stateless boot: networking, identity, default target, k3s left disabled.
[group('Virtual Machine')]
ephemeral-smoke tag=DEFAULT_TAG:
    #!/usr/bin/env bash
    set -euo pipefail
    script=$(base64 -w0 tests/ephemeral-smoke.sh)
    {{ BCVK }} ephemeral run-ssh "{{ local_image }}:{{ tag }}" -- "echo ${script} | base64 -d | sudo env EXPECT_IMAGE_NAME={{ IMAGE_NAME }} EXPECT_TAG={{ tag }} bash"

# Write a reusable QCOW2 disk from containers-storage.
[group('Virtual Machine')]
qcow2 tag=DEFAULT_TAG:
    mkdir -p output
    rm -f "output/{{ IMAGE_NAME }}.qcow2"
    {{ BCVK }} to-disk --target-transport containers-storage --filesystem btrfs --format qcow2 --disk-size 20G "{{ local_image }}:{{ tag }}" "output/{{ IMAGE_NAME }}.qcow2"

# Install and start a persistent rootless libvirt VM; reruns replace it.
[group('Virtual Machine')]
vm-create tag=DEFAULT_TAG:
    {{ BCVK }} libvirt --connect {{ BCVK_CONNECTION }} run --replace --name {{ vm_name }} --target-transport containers-storage --filesystem btrfs --disk-size 20G --detach --ssh-wait "{{ local_image }}:{{ tag }}"

# Check the persistent VM: identity, btrfs root, GDM, networking.
[group('Virtual Machine')]
vm-test tag=DEFAULT_TAG:
    {{ BCVK }} libvirt --connect {{ BCVK_CONNECTION }} ssh {{ vm_name }} 'set -eu; test "$(jq -r .\"image-name\" /usr/share/ublue-os/image-info.json)" = {{ IMAGE_NAME }}; bootc status --format=json | jq -e ".status.booted.image.image.image == \"{{ local_image }}:{{ tag }}\""; test "$(findmnt -no FSTYPE /sysroot)" = btrfs; systemctl is-active NetworkManager; test "$(systemctl get-default)" = graphical.target; systemctl is-active gdm; getent hosts fedoraproject.org; curl --silent --show-error --head --output /dev/null https://fedoraproject.org'

# Remove the persistent VM.
[group('Virtual Machine')]
vm-clean:
    {{ BCVK }} libvirt --connect {{ BCVK_CONNECTION }} rm --force {{ vm_name }}

# A separate VM large enough for k3s; k3s is enabled in it at test time.
[group('Virtual Machine')]
k3s-vm-create tag=DEFAULT_TAG:
    {{ BCVK }} libvirt --connect {{ BCVK_CONNECTION }} run --replace --name {{ k3s_vm_name }} --target-transport containers-storage --filesystem btrfs --memory 8G --cpus 4 --disk-size 40G --detach --ssh-wait "{{ local_image }}:{{ tag }}"

# Enable k3s in the test VM and run the image's bounded k3s acceptance check.
[group('Virtual Machine')]
k3s-vm-test:
    {{ BCVK }} libvirt --connect {{ BCVK_CONNECTION }} ssh {{ k3s_vm_name }} 'set -eu; systemctl enable --now k3s.service; /usr/libexec/k3s-validate'

# Install a composefs build in a disposable VM; check upgrade, switch, rollback.
[group('Virtual Machine')]
composefs-vm-test tag="composefs":
    tests/composefs-vm-test.sh "{{ local_image }}:{{ tag }}"

# Install a transient-/etc build in a disposable VM; report what writes /etc.
[group('Virtual Machine')]
transient-etc-vm-test tag="transient-etc" report="output/transient-etc-report.md":
    bash tests/transient-etc-vm-test.sh "{{ local_image }}:{{ tag }}" "{{ report }}"

# Remove the k3s test VM.
[group('Virtual Machine')]
k3s-vm-clean:
    {{ BCVK }} libvirt --connect {{ BCVK_CONNECTION }} rm --force {{ k3s_vm_name }}

# Nested-KVM KubeVirt acceptance in a disposable VM (KEEP_FAILED_VM=1 keeps a failed one).
[group('Virtual Machine')]
kubevirt-test tag=DEFAULT_TAG:
    #!/usr/bin/env bash
    set -euo pipefail
    name="{{ IMAGE_NAME }}-kubevirt-$(< /proc/sys/kernel/random/uuid)"
    created=0
    domain_uuid=''
    cleanup() {
        status=$?
        if ((status != 0 && ${KEEP_FAILED_VM:-0} == 1)); then
            printf 'Retaining failed VM %s\n' "${name}" >&2
        elif ((created)); then
            if current_uuid=$(virsh -c "${BCVK_CONNECTION}" domuuid "${name}" 2>/dev/null) && [[ "${current_uuid}" == "${domain_uuid}" ]]; then
                if ! "${BCVK}" libvirt --connect "${BCVK_CONNECTION}" rm --force "${name}"; then
                    printf 'Failed to remove %s; retaining state.\n' "${name}" >&2
                    status=1
                elif virsh -c "${BCVK_CONNECTION}" domuuid "${name}" >/dev/null 2>&1; then
                    printf 'Refusing success: %s still exists after removal.\n' "${name}" >&2
                    status=1
                fi
            else
                printf 'Refusing to remove %s: libvirt UUID is missing or changed; retaining state.\n' "${name}" >&2
                status=1
            fi
        fi
        exit "${status}"
    }
    trap cleanup EXIT
    nested=$(cat /sys/module/kvm_intel/parameters/nested /sys/module/kvm_amd/parameters/nested 2>/dev/null || true)
    if [[ ! "${nested}" =~ ^(Y|1)$ ]]; then
        echo "error: nested virtualization is not enabled on this host (kvm_intel or kvm_amd nested=1)" >&2
        exit 1
    fi
    if virsh -c "${BCVK_CONNECTION}" domuuid "${name}" >/dev/null 2>&1; then
        printf 'Refusing existing libvirt domain name %s\n' "${name}" >&2
        exit 1
    fi
    "${BCVK}" libvirt --connect "${BCVK_CONNECTION}" run --name "${name}" --target-transport containers-storage --filesystem btrfs --memory 16G --cpus 8 --disk-size 50G --detach --ssh-wait "{{ local_image }}:{{ tag }}"
    created=1
    domain_uuid=$(virsh -c "${BCVK_CONNECTION}" domuuid "${name}")
    virsh -c "${BCVK_CONNECTION}" dumpxml "${name}" | grep -Fq "<domain type='kvm'"
    virsh -c "${BCVK_CONNECTION}" dumpxml "${name}" | grep -Fq "<cpu mode='host-passthrough'"
    "${BCVK}" libvirt --connect "${BCVK_CONNECTION}" ssh "${name}" 'set -eu; echo K3S_PREFLIGHT_REQUIRE_KVM=1 > /etc/default/k3s-preflight; systemctl enable --now k3s.service'
    for _ in $(seq 1 5); do
        if "${BCVK}" libvirt --connect "${BCVK_CONNECTION}" ssh "${name}" 'K3S_VALIDATE_REQUIRE_KVM=1 /usr/libexec/k3s-validate'; then break; fi
        sleep 10
    done
    "${BCVK}" libvirt --connect "${BCVK_CONNECTION}" ssh "${name}" 'K3S_VALIDATE_REQUIRE_KVM=1 /usr/libexec/k3s-validate'
    fixture=$(tar -C tests/kubevirt -czf - acceptance.sh vm.yaml service.yaml | base64 -w0)
    "${BCVK}" libvirt --connect "${BCVK_CONNECTION}" ssh "${name}" "set -euo pipefail; fixture_dir=\$(mktemp -d /var/tmp/kubevirt-fixture.XXXXXX); trap 'rm -rf \${fixture_dir}' EXIT; printf '%s' '${fixture}' | base64 -d | tar -xzf - -C \"\${fixture_dir}\"; exec env KUBEVIRT_ACCEPTANCE=1 OUTER_LIBVIRT_UUID='${domain_uuid}' bash \"\${fixture_dir}/acceptance.sh\" \"\${fixture_dir}\""

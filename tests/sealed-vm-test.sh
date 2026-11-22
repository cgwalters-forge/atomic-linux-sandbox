#!/usr/bin/bash
# Build two local seals and exercise them on x86-64 OVMF with no built-in keys.
set -euo pipefail
umask 077

[[ $# == 3 ]] || { echo "usage: $0 LOCAL_IMAGE OVMF_SECBOOT_CODE OVMF_BLANK_VARS" >&2; exit 2; }
base=$1
podman=${PODMAN:-podman}
bcvk=${BCVK:-bcvk}
root=$(dirname "$(dirname "$(realpath "$0")")")
die() { echo "error: $*" >&2; exit 1; }

[[ $(uname -m) == x86_64 && -r /dev/kvm && -w /dev/kvm ]] || die 'this test needs accessible x86-64 KVM'
code=$(realpath -e "$2")
blank=$(realpath -e "$3")
for cmd in "$podman" "$bcvk" qemu-system-x86_64 qemu-img openssl cert-to-efi-sig-list \
    sign-efi-sig-list sbattach sbverify objcopy sfdisk mformat mmd mcopy; do
    command -v "$cmd" >/dev/null || die "missing $cmd"
done
"$podman" image exists "$base" || die "build or load $base locally first"

work=$(mktemp -d /var/tmp/atomic-linux-sealed.XXXXXXXX)
repo=localhost/${work##*/}
# Container image names must be lowercase.
repo=${repo,,}
label="atomic-linux.sealed-test=${repo##*/}"
vm_pid=
container=
cleanup() {
    local status=$? containers
    if [[ -n "$vm_pid" ]]; then
        kill "$vm_pid" 2>/dev/null || true
        wait "$vm_pid" 2>/dev/null || true
    fi
    if [[ -n "$container" ]]; then
        "$podman" rm -f "$container" >/dev/null || status=1
    fi
    containers=$("$podman" ps -aq --filter "label=$label") || status=1
    if [[ -n "$containers" ]]; then
        mapfile -t ids <<< "$containers"
        "$podman" rm -f "${ids[@]}" >/dev/null || status=1
    fi
    "$podman" rmi --ignore "$repo:installer" "$repo:one" "$repo:two" \
        "$repo:root-one" "$repo:root-two" >/dev/null || status=1
    rm -rf "$work" || status=1
    exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# Only the public cert and authenticated updates are build inputs. In
# particular neither an archive drive nor the build context contains keys.
keys=$work/private
public=$work/public
mkdir -p "$keys" "$public/auto"
guid=$(< /proc/sys/kernel/random/uuid)
for name in PK KEK db; do
    openssl req -new -x509 -sha256 -days 1 -newkey rsa:2048 -nodes \
        -subj "/CN=atomic-linux VM test $name/" -keyout "$keys/$name.key" \
        -out "$keys/$name.crt" 2>/dev/null || die "failed to generate test $name"
    cert-to-efi-sig-list -g "$guid" "$keys/$name.crt" "$keys/$name.esl"
done
for name in PK KEK db; do
    case "$name" in PK|KEK) signer=PK ;; db) signer=KEK ;; esac
    sign-efi-sig-list -k "$keys/$signer.key" -c "$keys/$signer.crt" \
        "$name" "$keys/$name.esl" "$public/auto/$name.auth"
done
cp "$keys/db.crt" "$public/db.crt"
rm "$keys/PK.key" "$keys/KEK.key"

fixture() {
    "$podman" build --pull=never --force-rm --layers=false -t "$repo:$2" \
        --build-arg "BASE_IMAGE=$base" --build-arg "MARKER=$1" --build-arg "TEST_REPO=$repo" \
        "$root/tests/sealed"
}

for version in one two; do
    fixture "$version" "root-$version"
    "$podman" build --pull=never --no-cache --layers=false --force-rm -t "$repo:$version" \
        --secret "id=secureboot_key,src=$keys/db.key" --build-arg "BASE_IMAGE=$repo:root-$version" \
        -f "$root/build/Containerfile.sealed" "$public"
done
rm "$keys/db.key"

# Read the expected digests from verified UKIs, independently of the guest.
for version in one two; do
    container=$("$podman" create "$repo:$version")
    "$podman" cp "$container:/boot/EFI/Linux/sealed.efi" "$work/$version.efi"
    "$podman" rm "$container" >/dev/null
    container=
    sbverify --cert "$public/db.crt" "$work/$version.efi"
    objcopy --dump-section ".cmdline=$work/$version.cmdline" "$work/$version.efi" /dev/null
    tr '\000 ' '\n' < "$work/$version.cmdline" |
        sed -nE 's/^composefs\.digest=v1-sha512-12:([0-9a-f]{128})$/\1/p' > "$work/$version.digest"
    grep -Ex '[0-9a-f]{128}' "$work/$version.digest"
    test "$(wc -l < "$work/$version.digest")" = 1
    "$podman" save -o "$work/$version.tar" "$repo:$version"
    # Block devices are sector-aligned; tar permits trailing zeroes.
    truncate -s %512 "$work/$version.tar"
done
one=$(< "$work/one.digest")
two=$(< "$work/two.digest")
[[ "$one" != "$two" ]] || die 'sealed images must have distinct root digests'

fixture installer installer
timeout -k 15s 25m "$bcvk" to-disk --label "$label" --target-transport containers-storage \
    --filesystem btrfs --karg console=ttyS0 --format qcow2 --disk-size 40G \
    "$repo:installer" "$work/installer.qcow2"
qemu-img create -f qcow2 "$work/target.qcow2" 40G
install -m 0600 "$blank" "$work/vars.fd"

qemu=(qemu-system-x86_64 -machine 'q35,smm=on,accel=kvm' -cpu host -smp 4 -m 8192
    -nodefaults -nographic -serial stdio -monitor none -nic none -boot strict=on
    -global 'driver=cfi.pflash01,property=secure,value=on'
    -drive "if=pflash,format=raw,unit=0,readonly=on,file=$code")
run_vm() {
    local phase=$1
    shift
    timeout -k 10s 25m "${qemu[@]}" -drive "if=pflash,format=raw,unit=1,file=$work/vars.fd" \
        "$@" </dev/null >"$work/$phase.log" 2>&1 &
    vm_pid=$!
    local status=0
    wait "$vm_pid" || status=$?
    vm_pid=
    if ((status != 0)) || grep -Fq 'SEALED TEST FAILED' "$work/$phase.log"; then
        tail -n 120 "$work/$phase.log" >&2
        die "$phase did not complete (QEMU exit $status)"
    fi
}

run_vm install \
    -drive "if=none,format=qcow2,id=boot,file=$work/installer.qcow2" -device virtio-blk-pci,drive=boot,bootindex=1 \
    -drive "if=none,format=qcow2,id=target,file=$work/target.qcow2" -device virtio-blk-pci,drive=target,serial=target \
    -drive "if=none,format=raw,readonly=on,id=payload,file=$work/one.tar" -device virtio-blk-pci,drive=payload,serial=payload
grep -F 'SEALED installer SecureBoot=0 SetupMode=1' "$work/install.log"
grep -F 'SEALED install complete' "$work/install.log"
rm "$work/installer.qcow2" "$work/one.tar"

run_vm sealed \
    -drive "if=none,format=qcow2,id=boot,file=$work/target.qcow2" -device virtio-blk-pci,drive=boot,bootindex=1 \
    -drive "if=none,format=raw,readonly=on,id=payload,file=$work/two.tar" -device virtio-blk-pci,drive=payload,serial=payload
grep -F 'Custom Secure Boot keys successfully enrolled, rebooting' "$work/sealed.log"
grep -F 'SEALED one SecureBoot=1 SetupMode=0' "$work/sealed.log"
grep -F "SEALED one root=$one" "$work/sealed.log"
grep -F 'SEALED two SecureBoot=1 SetupMode=0' "$work/sealed.log"
grep -F "SEALED two root=$two" "$work/sealed.log"
grep -F 'SEALED switch complete' "$work/sealed.log"

# Present only an unsigned copy of the second UKI to firmware. No signed
# loader, fallback deployment, other disk or network is present. The same
# bytes must reach Linux with blank vars, ruling out bad media or a bad PE.
sbattach --remove "$work/two.efi"
sbverify --list "$work/two.efi" 2>&1 | grep -Fx 'No signature table present'
negative=$work/negative.img
truncate -s 512M "$negative"
printf 'label: gpt\nstart=2048, size=1044480, type=U\n' | sfdisk "$negative"
esp="$negative@@1048576"
mformat -i "$esp" -F -T 1044480 ::
mmd -i "$esp" ::/EFI ::/EFI/BOOT
mcopy -i "$esp" "$work/two.efi" ::/EFI/BOOT/BOOTX64.EFI
install -m 0600 "$blank" "$work/control.fd"

boot_until() {
    local phase=$1 vars=$2 pattern=$3 settle=${4:-0}
    timeout -k 10s 120s "${qemu[@]}" -drive "if=pflash,format=raw,unit=1,file=$vars" \
        -drive "if=none,format=raw,readonly=on,id=boot,file=$negative" \
        -device virtio-blk-pci,drive=boot,bootindex=1 </dev/null >"$work/$phase.log" 2>&1 &
    vm_pid=$!
    while kill -0 "$vm_pid" 2>/dev/null; do
        if grep -E "$pattern" "$work/$phase.log"; then
            sleep "$settle"
            kill "$vm_pid" 2>/dev/null || true
            wait "$vm_pid" 2>/dev/null || true
            vm_pid=
            return
        fi
        sleep 1
    done
    tail -n 120 "$work/$phase.log" >&2
    die "expected $phase firmware result not observed"
}

boot_until unsigned-setup "$work/control.fd" 'Linux version [0-9]'
boot_until unsigned-enforced "$work/vars.fd" \
    'BdsDxe: failed to load Boot[[:xdigit:]]+ "UEFI [^"]+" from .*: (Access Denied|Security Violation)' 5
if grep -Eq 'Linux version [0-9]' "$work/unsigned-enforced.log"; then
    die 'unsigned UKI executed even with Secure Boot enabled'
fi
echo 'Secure Boot VM test passed'

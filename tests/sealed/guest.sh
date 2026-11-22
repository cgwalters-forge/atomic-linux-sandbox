#!/usr/bin/bash
set -euo pipefail
trap 'echo "SEALED TEST FAILED at line $LINENO"; systemctl --no-block poweroff' ERR

readonly vars=/sys/firmware/efi/efivars
readonly global=8be4df61-93ca-11d2-aa0d-00e098032b8c
readonly payload=/dev/disk/by-id/virtio-payload
readonly target=/dev/disk/by-id/virtio-target
readonly staged=/var/tmp/atomic-linux-sealed-test-staged
marker=$(< /usr/share/atomic-linux-sealed-test/marker)
repo=$(< /usr/share/atomic-linux-sealed-test/repo)

efi_byte() {
    # efivarfs prepends four attribute bytes to the value.
    od -An -j4 -N1 -tu1 "$vars/$1-$global" | tr -d '[:space:]'
}

secure=$(efi_byte SecureBoot)
setup=$(efi_byte SetupMode)
echo "SEALED $marker SecureBoot=$secure SetupMode=$setup"
if [[ "$marker" = installer ]]; then
    test "$secure:$setup" = 0:1
    test ! -e "$vars/PK-$global"
    test ! -e "$vars/KEK-$global"
    test ! -e "$vars/db-d719b2cb-3d3a-4596-a3bc-dad00e67656f"
    udevadm settle --timeout=30
    test -b "$target"
    podman load < "$payload"
    podman run --rm --pull=never --privileged --pid=host --net=none \
        --security-opt label=type:unconfined_t -v /sys:/sys:ro -v /dev:/dev \
        -v /var/lib/containers:/var/lib/containers -v /var/tmp:/var/tmp \
        "$repo:one" bootc install to-disk --generic-image --skip-fetch-check \
        --target-transport containers-storage "$target"
    echo 'SEALED install complete'
    systemctl --no-block poweroff
    exit
fi

test "$secure:$setup" = 1:0
digest=$(bootc status --format=json | jq -er '.status.booted.composefs |
    select(.bootloader == "systemd" and .missingVerityAllowed == false) | .verity')
test "$(findmnt -no SOURCE /)" = "composefs:$digest"
tr ' ' '\n' < /proc/cmdline | grep -Fx "composefs.digest=v1-sha512-12:$digest"
echo "SEALED $marker root=$digest"

case "$marker" in
    one)
        test ! -e "$staged"
        udevadm settle --timeout=30
        podman load < "$payload"
        bootc switch --transport containers-storage "$repo:two"
        touch "$staged"
        SYSTEMCTL_SKIP_AUTO_SOFT_REBOOT=1 systemctl --no-block reboot
        ;;
    two)
        test -f "$staged"
        echo 'SEALED switch complete'
        systemctl --no-block poweroff
        ;;
    *) exit 1 ;;
esac

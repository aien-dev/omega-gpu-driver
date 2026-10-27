#!/bin/sh
# usage: run.sh W0BIN CMDSFILE LOG   -- boots QEMU virt+SMMUv3 with 2x edu, runs /cmds, writes serial log to LOG
set -eu
[ $# -eq 3 ] || { echo "usage: $0 W0BIN CMDSFILE LOG" >&2; exit 2; }
B=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
# Guest kernel: the host's own Ubuntu image, extracted without root:
#   apt-get download linux-image-7.0.0-1019-nvidia && dpkg-deb -x linux-image-*.deb img
K=${KERNEL:-/tmp/ov-qemu/img/boot/vmlinuz-7.0.0-1019-nvidia}
[ -f $B/initramfs.cpio.gz ] || sh $B/mkinit.sh
T=$(mktemp -d "$B/run.XXXXXX")
trap 'rm -rf "$T"' EXIT
mkdir "$T/x"; cp "$1" "$T/x/w0"; chmod +x "$T/x/w0"; cp "$2" "$T/x/cmds"
cp $B/initramfs.cpio.gz "$T/initrd"
(cd "$T/x" && printf 'w0\ncmds\n' | cpio -o -H newc --quiet) | gzip >> "$T/initrd"
boot() { # $1 = accel args
  nice -n 19 taskset -c 8-9 timeout ${TIMEOUT:-180} qemu-system-aarch64 \
    -M virt,iommu=smmuv3 $1 -smp 2 -m 1G -nographic -no-reboot \
    -kernel $K -initrd "$T/initrd" -append 'console=ttyAMA0 rdinit=/init panic=-1' \
    -device edu -device edu
}
{ echo "### accel: KVM (-cpu host -enable-kvm)"; boot "-cpu host -enable-kvm"; } > "$3" 2>&1 && rc=0 || rc=$?
if [ $rc -ne 0 ] || ! grep -q 'bench done' "$3"; then
  mv "$3" "$3.kvmfail"
  { echo "### accel: TCG (-cpu max) after KVM rc=$rc"; boot "-cpu max"; } > "$3" 2>&1 || true
fi
grep -q 'bench done' "$3"

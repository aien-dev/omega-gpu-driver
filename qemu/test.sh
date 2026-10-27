#!/bin/sh
# qemu/test.sh -- build w0, boot the QEMU bench (virt + SMMUv3, edu 0000:00:02.0 on vfio-pci in group 2,
# a second edu 0000:00:03.0 left unbound), run qemu/w0.cmds and check every result.
# Usage: sh qemu/test.sh [LOG]   (KERNEL=... selects the guest kernel, see qemu/bench/run.sh)
set -eu
R=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
LOG=${1:-$R/build/w0-edu.log}
sh "$R/build.sh" >/dev/null
sh "$R/qemu/bench/run.sh" "$R/build/w0" "$R/qemu/w0.cmds" "$LOG"
fail=0
# one rc per command, in order: bind+read, wrong group, unbound edu, virtio (not vfio-pci),
# in-range extra read, read at the BAR0 size (oversized), misaligned read, usage, rebind after all
want="0 3 4 4 0 103 103 2 0"
got=$(tr -d '\r' < "$LOG" | sed -n 's/^\(.*[^0-9a-z_]\)\{0,1\}rc=\([0-9]*\)$/\2/p' | tr '\n' ' ' | sed 's/ $//')
[ "$got" = "$want" ] || { echo "FAIL rc sequence: got [$got] want [$want]"; fail=1; }
n=$(grep -c 'BOOT_0  \[0x000\]  mapget 0x010000ed pread 0x010000ed' "$LOG" || true)
[ "$n" = 5 ] || { echo "FAIL edu identity 0x010000ed via map and pread: $n of 5 runs"; fail=1; }
n=$(grep -c 'config vendor/device \[0x00\] 0x11e81234' "$LOG" || true)
[ "$n" = 5 ] || { echo "FAIL config vendor/device 1234:11e8: $n of 5 runs"; fail=1; }
n=$(grep -c 'released device, group and container' "$LOG" || true)
[ "$n" = 3 ] || { echo "FAIL release lines: $n of 3"; fail=1; }
grep -q 'REFUSED: device iommu_group does not match GROUP' "$LOG" || { echo "FAIL wrong-group refusal"; fail=1; }
[ "$(grep -c 'REFUSED: device is not bound to vfio-pci' "$LOG")" = 2 ] || { echo "FAIL unbound refusals"; fail=1; }
[ $fail = 0 ] && echo "PASS w0 QEMU bench: bind, read 0x010000ed, release; 5 refusals ($LOG)"
exit $fail

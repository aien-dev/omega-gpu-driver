#!/bin/sh
# Build initramfs.cpio.gz next to this script: static busybox + vfio-pci/iommufd modules + /init.
set -eu
B=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
KV=7.0.0-1019-nvidia
M=/lib/modules/$KV
BB=${BUSYBOX:-/bin/busybox}
file -L "$BB" | grep -q 'statically linked' || { echo "busybox $BB not static" >&2; exit 1; }
R=$(mktemp -d "$B/root.XXXXXX")
trap 'rm -rf "$R"' EXIT
mkdir -p "$R/bin" "$R/proc" "$R/sys" "$R/dev" "$R/lib/modules" "$R/tmp"
cp "$BB" "$R/bin/busybox"
for a in $("$BB" --list); do [ "$a" = busybox ] || ln -s busybox "$R/bin/$a"; done
# resolve deps from modules.dep: deps listed before the module itself, de-duplicated
order=""
add() { case " $order " in *" $1 "*) ;; *) order="$order $1";; esac; }
for want in kernel/drivers/vfio/pci/vfio-pci.ko.zst; do
  line=$(grep "^$want:" "$M/modules.dep") || { echo "missing $want" >&2; exit 1; }
  deps=${line#*:}
  rev=""; for d in $deps; do rev="$d $rev"; done   # modules.dep lists deepest dep last
  for d in $rev; do add "$d"; done
  add "$want"
done
: > "$R/lib/modules/order"
for m in $order; do
  n=$(basename "$m" .zst)
  zstd -q -d -c "$M/$m" > "$R/lib/modules/$n"
  echo "$n" >> "$R/lib/modules/order"
done
echo "modules: $(cat "$R/lib/modules/order" | tr '\n' ' ')"
cat > "$R/init" <<'INIT'
#!/bin/sh
export PATH=/bin
mount -t proc proc /proc
mount -t sysfs sysfs /sys
mount -t devtmpfs devtmpfs /dev
echo "=== bench init: $(uname -r)"
dmesg | grep -i smmu
for m in $(cat /lib/modules/order); do
  insmod /lib/modules/$m && echo "insmod $m ok" || echo "insmod $m FAILED"
done
edu=""; other=""
for d in /sys/bus/pci/devices/*; do
  v=$(cat $d/vendor); i=$(cat $d/device); b=${d##*/}
  echo "pci $b vendor=$v device=$i class=$(cat $d/class)"
  if [ "$v" = 0x1234 ] && [ "$i" = 0x11e8 ]; then
    if [ -z "$edu" ]; then edu=$b; elif [ -z "$other" ]; then other=$b; fi
  fi
done
[ -n "$edu" ] || { echo "NO EDU DEVICE"; poweroff -f; }
echo "=== edu bdf: $edu"
echo vfio-pci > /sys/bus/pci/devices/$edu/driver_override
[ -e /sys/bus/pci/devices/$edu/driver ] && echo $edu > /sys/bus/pci/devices/$edu/driver/unbind
echo $edu > /sys/bus/pci/drivers_probe
echo "edu driver: $(readlink /sys/bus/pci/devices/$edu/driver)"
ls -l /dev/vfio
echo "edu iommu_group: $(readlink /sys/bus/pci/devices/$edu/iommu_group)"
echo "=== second device (left unbound from vfio) bdf: $other"
echo "second iommu_group: $(readlink /sys/bus/pci/devices/$other/iommu_group)"
echo "second driver: $(readlink /sys/bus/pci/devices/$other/driver || echo none)"
echo "vfio-pci bound: $(ls /sys/bus/pci/drivers/vfio-pci | grep : | tr '\n' ' ')"
echo "=== cmds"
if [ -f /cmds ]; then
  while IFS= read -r c || [ -n "$c" ]; do
    [ -n "$c" ] || continue
    echo "\$ $c"
    sh -c "$c" </dev/null
    echo "rc=$?"
  done < /cmds
fi
echo "=== bench done, powering off"
poweroff -f
INIT
chmod +x "$R/init"
(cd "$R" && find . | cpio -o -H newc --quiet) | gzip -9 > "$B/initramfs.cpio.gz"
echo "wrote $B/initramfs.cpio.gz"

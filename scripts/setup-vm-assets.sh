#!/bin/sh
set -e

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ASSETS="$ROOT/VMAssets"
mkdir -p "$ASSETS"

ALPINE_URL="https://dl-cdn.alpinelinux.org/alpine/v3.20/releases/aarch64/alpine-virt-3.20.3-aarch64.iso"

echo "=== [1/4] Downloading Alpine Linux 3.20 ARM64 Virtual Image (69 MB) ==="
if [ ! -f "$ASSETS/alpine-virt-aarch64.iso" ]; then
    curl -fL -o "$ASSETS/alpine-virt-aarch64.iso" "$ALPINE_URL"
else
    echo "ISO already exists at $ASSETS/alpine-virt-aarch64.iso"
fi

echo "=== [2/4] Extracting Kernel & Initramfs ==="
tar -xf "$ASSETS/alpine-virt-aarch64.iso" -C "$ASSETS" boot/vmlinuz-virt boot/initramfs-virt
python3 -c "
import zlib
data = open('$ASSETS/boot/vmlinuz-virt', 'rb').read()
idx = data.find(b'\x1f\x8b\x08')
raw = zlib.decompress(data[idx:], 16 + zlib.MAX_WBITS)
open('$ASSETS/boot/Image', 'wb').write(raw)
print('Extracted raw ARM64 Linux kernel Image:', len(raw), 'bytes')
"

echo "=== [3/4] Creating 4GB Sparse Root Disk Image (base-rootfs.img) ==="
rm -f "$ASSETS/base-rootfs.img"
dd if=/dev/zero of="$ASSETS/base-rootfs.img" bs=1m count=0 seek=4096

echo "=== [4/4] Building & Running Automated VM Provisioner ==="
swiftc -parse-as-library "$ROOT/Sources/Provisioner.swift" -framework Virtualization -o "$ASSETS/provisioner"
codesign --force --sign - --entitlements "$ROOT/SafeSpace.entitlements" "$ASSETS/provisioner"
(cd "$ROOT" && "$ASSETS/provisioner")
rm -f "$ASSETS/provisioner"

echo "=== Done! VMAssets/base-rootfs.img is ready. Run ./build.sh to build SafeSpace.app ==="

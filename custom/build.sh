#!/bin/sh
# Build one device image from this branch.
# Usage: custom/build.sh <mx5300|mx4200v1> [make options, e.g. -j8]
#
# 1. feeds.conf pinned to the feed commits of the base release
# 2. feeds update/install, then the nss-packages patch from custom/patches
# 3. per-device files overlay (custom/files/<device>) and config (custom/configs/<device>.config)
# 4. make download && make
set -e
DEV=${1:?usage: custom/build.sh <mx5300|mx4200v1> [make options]}
shift
TOP=$(cd "$(dirname "$0")/.." && pwd)
C=$TOP/custom
[ -f "$C/configs/$DEV.config" ] || { echo "unknown device: $DEV" >&2; exit 1; }
cd "$TOP"

cp "$C/feeds.conf" feeds.conf
./scripts/feeds update -a
./scripts/feeds install -a

# nss-packages is a feed, so its patch is copied into the feed checkout.
cp "$C"/patches/nss_packages/qca-nss-clients/patches-11.4/*.patch \
	feeds/nss_packages/qca-nss-clients/patches-11.4/

rm -rf files
[ ! -d "$C/files/$DEV" ] || cp -a "$C/files/$DEV" files

cp "$C/configs/$DEV.config" .config
make defconfig
cmp -s .config "$C/configs/$DEV.config" || echo "WARNING: make defconfig changed .config" >&2

make download "$@"
make "$@"
ls -l bin/targets/qualcommax/ipq807x/*"$DEV"*

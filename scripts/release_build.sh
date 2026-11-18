#!/bin/bash
#
# Builds the firmware for every board in configs/ and writes a release
# manifest (firmware.json) and SHA256SUMS beside the images.
#
#   scripts/release_build.sh <output dir> [release name]
#
# Each board is built from the committed tree (HEAD) in a scratch clone,
# so Config.h in the working tree is never touched and uncommitted edits
# are not built. Boards whose host link is USB
# (STM32_USB_HOST) are built for the USB bootloader (make bl, loaded at
# 0x08002000 with dfu-util); the rest are flashed whole over the serial
# port (make, stm32flash from 0x08000000).
#
# Needs: arm-none-eabi-gcc, make, git, jq, sha256sum.

set -euo pipefail

OUT=$(realpath -m "${1:?usage: $0 <output dir> [release name]}")
SRC=$(cd "$(dirname "$0")/.." && pwd)
RELEASE=${2:-$(git -C "$SRC" describe --tags --always)}
COMMIT=$(git -C "$SRC" rev-parse HEAD)
SHORT=$(git -C "$SRC" rev-parse --short HEAD)

if [ ! -d "$SRC/STM32F10X_Lib/CMSIS" ]; then
	echo "STM32F10X_Lib is missing: git submodule update --init" >&2
	exit 1
fi

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$OUT"
rm -f "$OUT"/*_fw.bin "$OUT/firmware.json" "$OUT/SHA256SUMS"

boards='[]'
for config in "$SRC"/configs/*.h; do
	base=$(basename "$config" .h)
	file="${base,,}_fw.bin"

	if grep -qE '^[[:space:]]*#define[[:space:]]+STM32_USB_HOST\b' "$config"; then
		target=bl; image=mmdvm_f1bl.bin; host=usb
		flash='{"tool":"dfu-util","address":"0x08002000","device":"1eaf:0003","alt":2}'
	else
		target=hs; image=mmdvm_f1.bin; host=serial
		flash='{"tool":"stm32flash","address":"0x08000000"}'
	fi

	echo "=== $base ($target)"
	tree="$WORK/$base"
	# A clone of the commit (its own .git, so the Makefile stamps the
	# GitID), with the board's config as Config.h
	git clone --quiet "$SRC" "$tree"
	git -C "$tree" -c advice.detachedHead=false checkout --quiet "$COMMIT"
	cp -a "$SRC/STM32F10X_Lib/." "$tree/STM32F10X_Lib/"
	cp "$tree/configs/$base.h" "$tree/Config.h"
	make -C "$tree" -j"$(nproc)" "$target" >/dev/null
	cp "$tree/bin/$image" "$OUT/$file"

	# What the board will answer to GET_VERSION, read from the image itself
	description=$(strings -n 8 "$OUT/$file" | grep -m1 -E ' GitID #' || true)
	if [ -z "$description" ]; then
		echo "$base: no version string in $file" >&2
		exit 1
	fi
	duplex=false
	grep -qE '^[[:space:]]*#define[[:space:]]+DUPLEX\b' "$config" && duplex=true

	boards=$(jq --arg config "$base.h" --arg file "$file" --arg host "$host" \
		--arg sha "$(sha256sum "$OUT/$file" | cut -d' ' -f1)" \
		--argjson size "$(stat -c %s "$OUT/$file")" \
		--arg description "$description" --argjson duplex "$duplex" \
		--argjson flash "$flash" \
		'. + [{config: $config, file: $file, size: $size, sha256: $sha,
		       description: $description,
		       board: ($description | split("-v")[0]),
		       tcxo: ($description | capture(" (?<m>[0-9.]+)MHz ").m),
		       duplex: $duplex, host: $host, flash: $flash}]' <<<"$boards")
done

jq -n --arg release "$RELEASE" --arg commit "$COMMIT" --arg gitid "$SHORT" \
	--arg built "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --argjson boards "$boards" \
	'{release: $release, commit: $commit, gitid: $gitid, built: $built, boards: $boards}' \
	> "$OUT/firmware.json"

(cd "$OUT" && sha256sum -- *_fw.bin firmware.json > SHA256SUMS)

echo
jq -r '.boards[] | "\(.file)\t\(.board) \(.tcxo)MHz duplex=\(.duplex) \(.host)"' "$OUT/firmware.json" | column -t -s $'\t'

#!/bin/bash
#
# Builds the firmware for every board in boards.json and writes a release
# manifest (firmware.json) and SHA256SUMS beside the images.
#
#   scripts/release_build.sh <output dir> [release name]
#
# Each config is built once, from the committed tree (HEAD) in a scratch
# clone, so Config.h in the working tree is never touched and uncommitted
# edits are not built. Boards whose host link is USB (STM32_USB_HOST) are
# built for the USB bootloader (make bl, loaded at 0x08002000 with
# dfu-util); the rest are flashed whole over the serial port (make,
# stm32flash from 0x08000000, entering the bootloader through the board's
# BOOT0 and RESET GPIO lines).
#
# Fails when a configs/*.h is not used by any board, or when two images
# that report the same board, TCXO, duplex and host link differ (a
# running board could not then be told apart).
#
# Needs: arm-none-eabi-gcc, make, git, jq, sha256sum.

set -euo pipefail

OUT=$(realpath -m "${1:?usage: $0 <output dir> [release name]}")
SRC=$(cd "$(dirname "$0")/.." && pwd)
RELEASE=${2:-$(git -C "$SRC" describe --tags --always)}
COMMIT=$(git -C "$SRC" rev-parse HEAD)
SHORT=$(git -C "$SRC" rev-parse --short HEAD)
MAP=$(git -C "$SRC" show "$COMMIT:boards.json")

if [ ! -d "$SRC/STM32F10X_Lib/CMSIS" ]; then
	echo "STM32F10X_Lib is missing: git submodule update --init" >&2
	exit 1
fi

# The map: unique ids and aliases, configs that exist, every config used
dupes=$(jq -r '[.boards[] | .id, (.aliases // [])[]] | group_by(.) | map(select(length > 1) | .[0]) | .[]' <<<"$MAP")
if [ -n "$dupes" ]; then
	echo "boards.json: names used twice: $dupes" >&2
	exit 1
fi
configs=$(git -C "$SRC" ls-tree --name-only "$COMMIT" configs/ | sed 's|^configs/||' | grep '\.h$' | sort)
mapped=$(jq -r '.boards[].config' <<<"$MAP" | sort -u)
missing=$(comm -13 <(echo "$configs") <(echo "$mapped"))
unmapped=$(comm -23 <(echo "$configs") <(echo "$mapped"))
if [ -n "$missing" ] || [ -n "$unmapped" ]; then
	[ -n "$missing" ] && echo "boards.json: no such config: $missing" >&2
	[ -n "$unmapped" ] && echo "boards.json: configs no board uses: $unmapped" >&2
	exit 1
fi

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$OUT" "$WORK/images"
rm -f "$OUT"/*.bin "$OUT/firmware.json" "$OUT/SHA256SUMS"

defines() { grep -qE "^[[:space:]]*#define[[:space:]]+$2\b" "$1"; }

# Build each config once
for config in $mapped; do
	base=${config%.h}
	tree="$WORK/$base"
	git clone --quiet "$SRC" "$tree"
	git -C "$tree" -c advice.detachedHead=false checkout --quiet "$COMMIT"
	cp -a "$SRC/STM32F10X_Lib/." "$tree/STM32F10X_Lib/"
	cp "$tree/configs/$config" "$tree/Config.h"
	if defines "$tree/Config.h" STM32_USB_HOST; then
		target=bl; image=mmdvm_f1bl.bin
	else
		target=hs; image=mmdvm_f1.bin
	fi
	echo "=== $base ($target)"
	make -C "$tree" -j"$(nproc)" "$target" >/dev/null
	cp "$tree/bin/$image" "$WORK/images/$base.bin"
	cp "$tree/Config.h" "$WORK/images/$base.h"
	rm -rf "$tree"
done

# One image per board, with what it reports and how it is flashed
boards='[]'
while read -r entry; do
	id=$(jq -r .id <<<"$entry")
	base=$(jq -r '.config | rtrimstr(".h")' <<<"$entry")
	cp "$WORK/images/$base.bin" "$OUT/$id.bin"

	# What the board will answer to GET_VERSION, read from the image itself
	description=$(strings -n 8 "$OUT/$id.bin" | grep -m1 -E ' GitID #' || true)
	if [ -z "$description" ]; then
		echo "$id: no version string in its image" >&2
		exit 1
	fi
	duplex=false
	defines "$WORK/images/$base.h" DUPLEX && duplex=true
	if defines "$WORK/images/$base.h" STM32_USB_HOST; then
		host=usb
		flash='{"tool": "dfu-util", "address": "0x08002000", "device": "1eaf:0003", "alt": 2}'
		if jq -e 'has("gpio") or has("port")' <<<"$entry" >/dev/null; then
			echo "boards.json: $id is a USB board: no gpio or port" >&2
			exit 1
		fi
	else
		host=serial
		if ! jq -e '.gpio.boot0 and .gpio.reset' <<<"$entry" >/dev/null; then
			echo "boards.json: $id is on the serial port: it needs gpio boot0 and reset" >&2
			exit 1
		fi
		flash=$(jq -c '{tool: "stm32flash", address: "0x08000000", gpio} + (if .port then {port} else {} end)' <<<"$entry")
	fi

	boards=$(jq --argjson entry "$entry" --arg file "$id.bin" --arg host "$host" \
		--arg sha "$(sha256sum "$OUT/$id.bin" | cut -d' ' -f1)" \
		--argjson size "$(stat -c %s "$OUT/$id.bin")" \
		--arg description "$description" --argjson duplex "$duplex" \
		--argjson flash "$flash" \
		'. + [{id: $entry.id, name: $entry.name, aliases: ($entry.aliases // []),
		       config: $entry.config, file: $file, size: $size, sha256: $sha,
		       description: $description,
		       board: ($description | split("-v")[0]),
		       tcxo: ($description | capture(" (?<m>[0-9.]+)MHz ").m),
		       duplex: $duplex, host: $host, flash: $flash}]' <<<"$boards")
done < <(jq -c '.boards[]' <<<"$MAP")

# A running board is identified by what it reports and how it is connected:
# images that share all of that must be the same image
clash=$(jq -r 'group_by([.board, .tcxo, .duplex, .host])
	| map(select((map(.sha256) | unique | length) > 1) | map(.id) | join(", ")) | .[]' <<<"$boards")
if [ -n "$clash" ]; then
	echo "Boards that report the same but take different images: $clash" >&2
	exit 1
fi

jq -n --arg release "$RELEASE" --arg commit "$COMMIT" --arg gitid "$SHORT" \
	--arg built "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --argjson boards "$boards" \
	'{release: $release, commit: $commit, gitid: $gitid, built: $built, boards: $boards}' \
	> "$OUT/firmware.json"

(cd "$OUT" && sha256sum -- *.bin firmware.json > SHA256SUMS)

echo
jq -r '.boards[] | "\(.file)\t\(.board) \(.tcxo)MHz duplex=\(.duplex) \(.host)\t\(.sha256[0:12])"' "$OUT/firmware.json" | column -t -s $'\t'

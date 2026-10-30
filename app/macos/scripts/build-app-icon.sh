#!/bin/bash
set -euo pipefail
ICON_PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ICON_SOURCE="$ICON_PROJECT_ROOT/Resources/AppIcon-generated.png"
ICON_OUTPUT="$ICON_PROJECT_ROOT/Resources/AppIcon.icns"
ICON_TEMP="$(mktemp -d "${TMPDIR:-/tmp}/workbench-icon.XXXXXX")"
trap 'rm -rf "$ICON_TEMP"' EXIT
ICON_SET="$ICON_TEMP/AppIcon.iconset"
mkdir -p "$ICON_SET"
for ICON_SIZE in 16 32 128 256 512; do
    /usr/bin/sips -z "$ICON_SIZE" "$ICON_SIZE" "$ICON_SOURCE" --out "$ICON_SET/icon_${ICON_SIZE}x${ICON_SIZE}.png" >/dev/null
    ICON_DOUBLE="$((ICON_SIZE * 2))"
    /usr/bin/sips -z "$ICON_DOUBLE" "$ICON_DOUBLE" "$ICON_SOURCE" --out "$ICON_SET/icon_${ICON_SIZE}x${ICON_SIZE}@2x.png" >/dev/null
done
/usr/bin/iconutil -c icns "$ICON_SET" -o "$ICON_OUTPUT"
cp "$ICON_SET/icon_512x512@2x.png" "$ICON_PROJECT_ROOT/Resources/AppIcon-1024.png"
printf '%s\n' "$ICON_OUTPUT"

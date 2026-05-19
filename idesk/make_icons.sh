#!/bin/sh
set -e
DEST="$HOME/.idesktop"
BASE="/usr/share/icons/gnome/48x48/devices/network-vpn.png"
EMBLEM="/usr/share/icons/gnome/16x16/emblems/emblem-default.png"
mkdir -p "$DEST"

convert "$BASE" "$EMBLEM" -gravity SouthEast -composite "$DEST/vpn-on.png"
cp "$BASE" "$DEST/vpn-off.png"

echo "[done]  Generated $DEST/vpn-on.png and $DEST/vpn-off.png"

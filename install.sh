#!/bin/bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FORCE="${1:-}"

info()  { echo "[info]  $*"; }
warn()  { echo "[warn]  $*"; }
done_() { echo "[done]  $*"; }

# ── Step 1: Check required apt packages ────────────────────────────────────
info "Checking required packages..."

# Packages required by scripts in bin/:
#   dunst        → dunstify notifications (battery, brightness, volume, screen-notify, usb-device-notify)
#   brightnessctl → brightness control
#   pulseaudio-utils → pactl (volume, usb-device-notify)
#   usbutils     → lsusb (usb-device-notify)
#   x11-xserver-utils → xrandr + xset (laptop-dock.sh, screen-notify, autostart)
#   wmctrl       → window management (laptop-dock.sh)
#   xbindkeys    → hardware media/function key bindings (.xbindkeysrc)
#   xss-lock     → screen lock trigger (autostart)
#   xsecurelock  → screen locker (autostart, WMRootMenu)
#   python3-pyqt5 → padlock.py
#   python3-gi + python3-gi-cairo + gir1.2-gtk-3.0 → padlock-gtk.py
#   python3-pil  → saver-wallpaper
#   python3-xlib → saver-wallpaper
#   imagemagick  → idesk/make_icons.sh
#   idesk        → desktop icon manager
APT_PACKAGES=(
    dunst
    brightnessctl
    pulseaudio-utils
    usbutils
    x11-xserver-utils
    wmctrl
    xbindkeys
    xss-lock
    xsecurelock
    python3-pyqt5
    python3-gi
    python3-gi-cairo
    "gir1.2-gtk-3.0"
    python3-pil
    python3-xlib
    imagemagick
    idesk
)

MISSING=()
for pkg in "${APT_PACKAGES[@]}"; do
    if ! dpkg -l "$pkg" 2>/dev/null | grep -q "^ii"; then
        MISSING+=("$pkg")
    fi
done

if [[ ${#MISSING[@]} -eq 0 ]]; then
    done_ "All required apt packages are installed."
else
    warn "Missing packages: ${MISSING[*]}"
fi

# ── Step 2: Shell config ────────────────────────────────────────────────────
info "Setting up shell config..."

for dotfile in .bashrc .xbindkeysrc; do
    src="$REPO_DIR/shell/$dotfile"
    dst="$HOME/$dotfile"
    if [[ -f "$dst" && ! -L "$dst" ]]; then
        cp "$dst" "${dst}.bak"
        warn "Backed up $dst to ${dst}.bak"
    fi
    if [[ -L "$dst" && "$FORCE" != "--force" ]]; then
        warn "$dst is already a symlink. Skipping. Use --force to overwrite."
    else
        ln -sf "$src" "$dst"
        done_ "$dst → $src"
    fi
done

# ── Step 3: WindowMaker config ──────────────────────────────────────────────
info "Setting up WindowMaker config..."

mkdir -p "$HOME/GNUstep/Defaults" "$HOME/GNUstep/Library/WindowMaker"

for src in \
    "wmaker/Defaults/WindowMaker:$HOME/GNUstep/Defaults/WindowMaker" \
    "wmaker/Defaults/WMRootMenu:$HOME/GNUstep/Defaults/WMRootMenu" \
    "wmaker/Library/WindowMaker/autostart:$HOME/GNUstep/Library/WindowMaker/autostart"
do
    rel="${src%%:*}"
    dst="${src##*:}"
    if [[ -f "$dst" && "$FORCE" != "--force" ]]; then
        warn "$dst already exists. Skipping. Use --force to overwrite."
    else
        cp "$REPO_DIR/$rel" "$dst"
        done_ "Installed $dst"
    fi
done

# ── Step 4: Local config ────────────────────────────────────────────────────
info "Setting up local config..."

mkdir -p "$HOME/.config/dotfiles"

if [[ -f "$HOME/.config/dotfiles/local.env" ]]; then
    warn "~/.config/dotfiles/local.env already exists. Skipping."
else
    cp "$REPO_DIR/local.env.example" "$HOME/.config/dotfiles/local.env"
    done_ "Created ~/.config/dotfiles/local.env from template"
    warn "→ Edit ~/.config/dotfiles/local.env and fill in VPN_GATEWAY, VPN_GROUP, DAC_VENDOR_ID, DAC_PRODUCT_ID, DAC_SINK_NAME, SYSTEM_SINK_NAME, and AUDIO_CARD."
fi

if [[ -f "$HOME/.pbwidget" ]]; then
    warn "~/.pbwidget already exists. Skipping."
else
    cp "$REPO_DIR/pbwidget.conf.example" "$HOME/.pbwidget"
    done_ "Created ~/.pbwidget from template"
    warn "→ Edit ~/.pbwidget and set DEVICE_MAC to your Pixel Buds MAC address."
fi

# ── Step 5: iDesk setup ─────────────────────────────────────────────────────
info "Setting up iDesk..."

mkdir -p "$HOME/.idesktop"
bash "$REPO_DIR/idesk/make_icons.sh"

if pgrep -x gpclient > /dev/null 2>&1; then
    ln -sf "$HOME/.idesktop/vpn-on.png" "$HOME/.idesktop/vpn-current.png"
else
    ln -sf "$HOME/.idesktop/vpn-off.png" "$HOME/.idesktop/vpn-current.png"
fi
done_ "Set ~/.idesktop/vpn-current.png"

vpn_lnk_dst="$HOME/.idesktop/vpn.lnk"
if [[ -f "$vpn_lnk_dst" && "$FORCE" != "--force" ]]; then
    warn "$vpn_lnk_dst already exists. Skipping. Use --force to overwrite."
else
    sed "s|HOME_DIR|$HOME|g" "$REPO_DIR/idesk/vpn.lnk" > "$vpn_lnk_dst"
    done_ "Installed $vpn_lnk_dst"
fi

ideskrc_dst="$HOME/.ideskrc"
if [[ -f "$ideskrc_dst" && ! -L "$ideskrc_dst" && "$FORCE" != "--force" ]]; then
    cp "$ideskrc_dst" "${ideskrc_dst}.bak"
    warn "Backed up $ideskrc_dst to ${ideskrc_dst}.bak"
fi
if [[ -f "$ideskrc_dst" && "$FORCE" != "--force" ]]; then
    warn "$ideskrc_dst already exists. Skipping. Use --force to overwrite."
else
    cp "$REPO_DIR/idesk/dot.ideskrc" "$ideskrc_dst"
    done_ "Installed $ideskrc_dst"
fi

# ── Step 6: Print sudo instructions ────────────────────────────────────────
echo ""
echo "══════════════════════════════════════════════════════════"
echo "  Manual steps required (run these yourself with sudo):"
echo "══════════════════════════════════════════════════════════"
echo ""

if [[ ${#MISSING[@]} -gt 0 ]]; then
    echo "  # Install missing apt packages:"
    echo "  sudo apt install ${MISSING[*]}"
    echo ""
fi

echo "  # gpclient (GlobalProtect VPN — not in apt):"
echo "  #   Download the .deb from https://github.com/yuezk/GlobalProtect-openconnect/releases"
echo "  #   sudo dpkg -i globalprotect-openconnect_*.deb"
echo ""
echo "  # Install scripts to /usr/local/bin:"
echo "  sudo cp $REPO_DIR/bin/* /usr/local/bin/"
echo "  sudo chmod +x $(ls "$REPO_DIR/bin/" | sed "s|^|/usr/local/bin/|" | tr '\n' ' ')"
echo ""
echo "  # Install udev rules (paths are expanded from templates):"
for rule in "$REPO_DIR"/udev/*.rules; do
    rule_name="$(basename "$rule")"
    echo "  sudo sed 's|DOTFILES_PATH|$REPO_DIR/bin|g' $rule > /etc/udev/rules.d/$rule_name" | sed "s|\$REPO_DIR|$REPO_DIR|g"
done
echo "  sudo udevadm control --reload-rules && sudo udevadm trigger"
echo ""
echo "  # Install and enable systemd user services:"
echo "  mkdir -p ~/.config/systemd/user"
for svc in "$REPO_DIR"/systemd/*.service; do
    svc_name="$(basename "$svc")"
    echo "  cp $svc ~/.config/systemd/user/$svc_name"
    echo "  systemctl --user enable --now $svc_name"
done
echo ""
echo "  # Install sudoers snippets (validated before install):"
for snippet in "$REPO_DIR"/sudoers/*; do
    snippet_name="$(basename "$snippet")"
    dest="/etc/sudoers.d/$snippet_name"
    tmp="/tmp/$snippet_name.sudoers.tmp"
    echo "  sed 's/USERNAME/$(whoami)/g' $snippet > $tmp \\"
    echo "    && visudo -c -f $tmp \\"
    echo "    && sudo install -m 0440 $tmp $dest \\"
    echo "    && rm $tmp"
done
echo ""
echo "══════════════════════════════════════════════════════════"

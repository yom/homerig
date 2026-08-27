# homerig

Personal Debian workstation toolkit — scripts, udev rules, and configuration for a ThinkPad running WindowMaker.

## What's in here

| Path | Contents |
|---|---|
| `bin/` | Daily-use scripts, installed to `/usr/local/bin` |
| `shell/` | `.bashrc`, `.xbindkeysrc` (hardware media/function keys) |
| `wmaker/` | WindowMaker settings, root menu, autostart |
| `systemd/` | systemd user units |
| `udev/` | udev rules |
| `sudoers/` | sudoers snippets (username injected at install time) |
| `idesk/` | Desktop icon definitions and generation script |
| `local.env.example` | Template for `~/.config/dotfiles/local.env` (machine-specific values, gitignored) |

## Scripts

| Script | Description |
|---|---|
| `battery` | Battery status notifications via dunst, with Yaru symbolic icons |
| `battery-gauge` | Renders a battery gauge PNG for richer notifications |
| `vpn` | GlobalProtect VPN toggle — connects, disconnects, or recovers a stuck tunnel |
| `vpn-nm-dispatcher` | NetworkManager dispatcher hook — syncs VPN state on network changes |
| `vpn-sleep-hook` | systemd-sleep hook — tears down VPN before suspend, refreshes on wake |
| `fprintd-notify` | Daemon listening to fprintd D-Bus signals, shows dunst notifications on fingerprint auth |
| `brightness` | Screen brightness control (brightnessctl) with notification |
| `volume` | Volume control (pactl) with notification |
| `laptop-dock` | Detects dock/undock events and reconfigures displays via xrandr |
| `screen-notify` | Notifies on screen lock/unlock (xss-lock) |
| `screenshot` | Screenshot to clipboard |
| `usb-device-notify` | Notifies when specific USB devices connect or disconnect |
| `padlock` / `padlock-gtk` | GUI lock screen launcher (PyQt5 / GTK) |
| `saver-wallpaper` | Sets a wallpaper from a saved image on screensaver activation |
| `chrome-profile-wrapper` | Launches Chrome with a specific profile (used by VPN browser auth) |

## Setup

```bash
git clone https://github.com/yom/homerig
cd homerig
./install.sh
# Then run the printed sudo commands
```

`install.sh` handles symlinks, copies, and prints the privileged steps to run manually. Machine-specific values (VPN gateway, audio device IDs, etc.) go in `~/.config/dotfiles/local.env` — see `local.env.example`.

## Dependencies

Managed by `install.sh` — it checks and lists any missing packages on each run.

# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository Overview

Personal dotfiles repository for a Debian/ThinkPad machine running WindowMaker. Contains shell config, daily-use scripts, udev rules, GUI utilities, and WindowMaker configuration.

## File Structure

- `bin/` — Daily-use scripts, installed to `/usr/local/bin`
- `udev/` — udev rules, installed to `/etc/udev/rules.d`
- `shell/.bashrc` — Main bash config, symlinked to `~/.bashrc`
- `shell/.xbindkeysrc` — Hardware media/function key bindings, symlinked to `~/.xbindkeysrc`
- `wmaker/Defaults/WindowMaker` — WindowMaker settings and keybindings
- `wmaker/Defaults/WMRootMenu` — Root menu and application shortcuts (all keybindings using Mod1+key)
- `wmaker/Library/WindowMaker/autostart` — Session startup commands (xset, xss-lock)
- `local.env.example` — Template for `~/.config/dotfiles/local.env` (machine-specific values, not tracked)
- `install.sh` — Setup script: run once after cloning

## Setup

```bash
./install.sh
# Then follow the printed sudo instructions
```

## Sensitive Values

The `bin/vpn` script reads `VPN_GATEWAY` and `VPN_GROUP` from `~/.config/dotfiles/local.env`. That file is gitignored. `local.env.example` is the template.

## No Build/Test Commands

This repository contains configuration files and shell scripts — no build, test, or lint commands are applicable.

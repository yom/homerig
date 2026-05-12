#!/usr/bin/env python3

import sys
import subprocess
import argparse
import shlex
import gi
import math
from gi.repository import GdkPixbuf

gi.require_version('Gtk', '3.0')
gi.require_version('Gdk', '3.0')
from gi.repository import Gtk, Gdk, GdkPixbuf
import cairo

class PadlockToggle(Gtk.Window):
    def __init__(self, lock_cmd, unlock_cmd):
        super().__init__()
        self.is_locked = False
        self.process = None
        self.lock_cmd = lock_cmd
        self.unlock_cmd = unlock_cmd
        self.init_ui()

    def init_ui(self):
        # Set window properties
        self.set_title('Padlock Toggle')
        self.set_default_size(40, 40)
        self.set_resizable(False)
        self.set_decorated(False)  # Remove window decorations
        self.set_keep_above(True)  # Always on top
        self.set_app_paintable(True)  # Allow custom drawing

        # Use desktop wallpaper color or make it very small and rounded
        self.set_style_classes()

        # Position window
        self.position_window()

        # Connect events
        self.connect('draw', self.on_draw)
        self.connect('button-press-event', self.on_click)
        self.connect('destroy', self.on_destroy)

        # Enable mouse events
        self.set_events(Gdk.EventMask.BUTTON_PRESS_MASK)

        # Set cursor
        cursor = Gdk.Cursor.new_from_name(self.get_display(), "pointer")
        self.get_window().set_cursor(cursor) if self.get_window() else None

    def position_window(self):
        # Position in top-right corner
        display = Gdk.Display.get_default()
        monitor = display.get_primary_monitor()
        geometry = monitor.get_geometry()
        x = geometry.width - 80  # 80px from right edge
        y = 20  # 20px from top edge
        self.move(x, y)

    def set_style_classes(self):
        # Apply CSS styling for a more integrated look
        css_provider = Gtk.CssProvider()
        css = """
        window {
            background-color: transparent;
            border-radius: 20px;
            border: 2px solid rgba(100, 100, 100, 0.3);
        }
        """
        css_provider.load_from_data(css.encode())

        style_context = self.get_style_context()
        style_context.add_provider(css_provider, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION)

    def on_draw(self, widget, cr):
        # Make the window truly round by clipping
        width = self.get_allocated_width()
        height = self.get_allocated_height()

        # Create circular clipping path
        cr.arc(width/2, height/2, min(width, height)/2 - 2, 0, 2 * math.pi)
        cr.clip()

        # Set background to match typical desktop colors
        cr.set_source_rgb(0.2, 0.2, 0.3)  # Dark blue-gray typical of many desktops
        cr.paint()

        # Draw padlock icon
        self.draw_padlock(cr)
        return False

    def draw_padlock(self, cr):
        # Get widget dimensions
        width = self.get_allocated_width()
        height = self.get_allocated_height()

        # Center the icon
        center_x = width / 2
        center_y = height / 2
        size = min(width, height) * 0.6

        if self.is_locked:
            # Draw locked padlock (red)
            cr.set_source_rgb(0.8, 0.2, 0.2)  # Solid red
        else:
            # Draw unlocked padlock (green)
            cr.set_source_rgb(0.2, 0.8, 0.2)  # Solid green

        # Draw padlock body
        body_width = size * 0.6
        body_height = size * 0.5
        body_x = center_x - body_width / 2
        body_y = center_y - body_height / 2 + size * 0.1

        cr.rectangle(body_x, body_y, body_width, body_height)
        cr.fill()

        # Draw padlock shackle
        shackle_radius = size * 0.25
        shackle_x = center_x
        shackle_y = center_y - size * 0.2

        cr.set_line_width(size * 0.1)
        cr.set_source_rgb(0.3, 0.3, 0.3)  # Dark gray

        if self.is_locked:
            # Closed shackle
            cr.arc(shackle_x, shackle_y, shackle_radius, math.pi, 2 * math.pi)
        else:
            # Open shackle
            cr.arc(shackle_x, shackle_y, shackle_radius, math.pi, math.pi * 1.7)

        cr.stroke()

        # Draw keyhole
        keyhole_x = center_x
        keyhole_y = center_y + size * 0.05
        keyhole_radius = size * 0.08

        cr.set_source_rgb(0, 0, 0)  # Black keyhole
        cr.arc(keyhole_x, keyhole_y, keyhole_radius, 0, 2 * math.pi)
        cr.fill()

        # Keyhole slot
        slot_width = size * 0.04
        slot_height = size * 0.15
        cr.rectangle(keyhole_x - slot_width/2, keyhole_y, slot_width, slot_height)
        cr.fill()

    def on_click(self, widget, event):
        if event.button == 1:  # Left click
            self.toggle_connection()

    def toggle_connection(self):
        if self.is_locked:
            self.run_unlock_command()
        else:
            self.run_lock_command()

        # Toggle state and redraw
        self.is_locked = not self.is_locked
        self.queue_draw()

    def run_lock_command(self):
        if not self.lock_cmd:
            print("No lock command configured")
            return
        try:
            cmd_parts = shlex.split(self.lock_cmd)
            self.process = subprocess.Popen(cmd_parts,
                                          stdout=subprocess.DEVNULL,
                                          stderr=subprocess.DEVNULL)
            print(f"Lock command executed: {self.lock_cmd}")
        except FileNotFoundError:
            print(f"Error: Command not found: {self.lock_cmd}")
        except Exception as e:
            print(f"Error executing lock command: {e}")

    def run_unlock_command(self):
        if not self.unlock_cmd:
            print("No unlock command configured")
            return
        try:
            if self.process and self.process.poll() is None:
                self.process.terminate()
                self.process.wait()

            cmd_parts = shlex.split(self.unlock_cmd)
            subprocess.run(cmd_parts,
                         stdout=subprocess.DEVNULL,
                         stderr=subprocess.DEVNULL)
            print(f"Unlock command executed: {self.unlock_cmd}")
        except FileNotFoundError:
            print(f"Error: Command not found: {self.unlock_cmd}")
        except Exception as e:
            print(f"Error executing unlock command: {e}")

    def on_destroy(self, widget):
        if self.process and self.process.poll() is None:
            self.process.terminate()
            self.process.wait()
        Gtk.main_quit()

def parse_args():
    parser = argparse.ArgumentParser(description='Padlock Toggle - Visual toggle for running/stopping commands')
    parser.add_argument('--lock-cmd', type=str, help='Command to run when locking (clicking unlocked padlock)')
    parser.add_argument('--unlock-cmd', type=str, help='Command to run when unlocking (clicking locked padlock)')
    return parser.parse_args()

def main():
    args = parse_args()

    if not args.lock_cmd and not args.unlock_cmd:
        print("Error: At least one of --lock-cmd or --unlock-cmd must be specified")
        print("\nExample usage:")
        print("  padlock-gtk.py --lock-cmd 'globalconnect' --unlock-cmd 'pkill globalconnect'")
        sys.exit(1)

    # Create and show the padlock toggle
    app = PadlockToggle(args.lock_cmd, args.unlock_cmd)
    app.show_all()

    Gtk.main()

if __name__ == '__main__':
    main()
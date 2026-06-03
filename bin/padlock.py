#!/usr/bin/env python3

import sys
import subprocess
import argparse
import shlex
from PyQt5.QtWidgets import QApplication, QLabel, QWidget
from PyQt5.QtCore import Qt
from PyQt5.QtGui import QFont, QCursor, QPixmap, QPainter, QBrush, QPen
from PyQt5.QtSvg import QSvgRenderer

class PadlockToggle(QWidget):
    def __init__(self, lock_cmd, unlock_cmd):
        super().__init__()
        self.is_locked = False
        self.process = None
        self.lock_cmd = lock_cmd
        self.unlock_cmd = unlock_cmd
        self.init_ui()

    def init_ui(self):
        # Set window properties - clean, borderless window
        self.setWindowTitle('Padlock Toggle')
        self.setFixedSize(60, 60)
        self.setWindowFlags(Qt.FramelessWindowHint | Qt.WindowStaysOnTopHint | Qt.Tool)

        # Set a clean light background
        self.setStyleSheet("""
            QWidget {
                background-color: #f0f0f0;
                border: 1px solid #ccc;
                border-radius: 8px;
            }
        """)

        # Create the padlock label
        self.padlock_label = QLabel(self)
        self.padlock_label.setAlignment(Qt.AlignCenter)
        self.padlock_label.setCursor(QCursor(Qt.PointingHandCursor))
        self.padlock_label.setGeometry(6, 6, 48, 48)
        self.padlock_label.setStyleSheet("border: none; background-color: transparent;")

        # Create lock/unlock icons
        self.create_icons()

        # Set initial unlocked state
        self.update_padlock_display()

        # Position the window in top-right corner
        self.position_window()

    def position_window(self):
        # Position in top-right corner instead of center
        screen = QApplication.desktop().screenGeometry()
        x = screen.width() - self.width() - 20  # 20px from right edge
        y = 20  # 20px from top edge
        self.move(x, y)

    def create_icons(self):
        # Create locked icon (closed padlock)
        self.locked_pixmap = QPixmap(48, 48)
        self.locked_pixmap.fill(Qt.transparent)
        painter = QPainter(self.locked_pixmap)
        painter.setRenderHint(QPainter.Antialiasing)

        # Draw locked padlock with better colors
        painter.setBrush(QBrush(Qt.red))  # Red for locked
        painter.setPen(QPen(Qt.darkRed, 2))
        # Body of lock
        painter.drawRoundedRect(14, 22, 20, 16, 2, 2)
        # Shackle (closed)
        painter.setBrush(Qt.NoBrush)
        painter.setPen(QPen(Qt.darkRed, 3))
        painter.drawArc(18, 12, 12, 12, 0, 180 * 16)
        # Keyhole
        painter.setBrush(QBrush(Qt.white))
        painter.setPen(Qt.NoPen)
        painter.drawEllipse(22, 27, 4, 4)
        painter.drawRect(23, 29, 2, 4)
        painter.end()

        # Create unlocked icon (open padlock)
        self.unlocked_pixmap = QPixmap(48, 48)
        self.unlocked_pixmap.fill(Qt.transparent)
        painter = QPainter(self.unlocked_pixmap)
        painter.setRenderHint(QPainter.Antialiasing)

        # Draw unlocked padlock with better colors
        painter.setBrush(QBrush(Qt.green))  # Green for unlocked
        painter.setPen(QPen(Qt.darkGreen, 2))
        # Body of lock
        painter.drawRoundedRect(14, 22, 20, 16, 2, 2)
        # Shackle (open)
        painter.setBrush(Qt.NoBrush)
        painter.setPen(QPen(Qt.darkGreen, 3))
        painter.drawArc(18, 12, 12, 12, 0, 140 * 16)  # Partial arc for open look
        # Keyhole
        painter.setBrush(QBrush(Qt.white))
        painter.setPen(Qt.NoPen)
        painter.drawEllipse(22, 27, 4, 4)
        painter.drawRect(23, 29, 2, 4)
        painter.end()

    def update_padlock_display(self):
        if self.is_locked:
            self.padlock_label.setPixmap(self.locked_pixmap)
            self.padlock_label.setToolTip('Click to unlock (run unlock command)')
        else:
            self.padlock_label.setPixmap(self.unlocked_pixmap)
            self.padlock_label.setToolTip('Click to lock (run lock command)')

    def mousePressEvent(self, event):
        if event.button() == Qt.LeftButton:
            self.toggle_connection()

    def toggle_connection(self):
        if self.is_locked:
            # Unlock - run unlock command
            self.run_unlock_command()
        else:
            # Lock - run lock command
            self.run_lock_command()

        # Toggle state and update display
        self.is_locked = not self.is_locked
        self.update_padlock_display()

    def run_lock_command(self):
        if not self.lock_cmd:
            print("No lock command configured")
            return
        try:
            # Parse and run the lock command
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
            # Kill the previous process if it's still running
            if self.process and self.process.poll() is None:
                self.process.terminate()
                self.process.wait()

            # Parse and run the unlock command
            cmd_parts = shlex.split(self.unlock_cmd)
            subprocess.run(cmd_parts,
                         stdout=subprocess.DEVNULL,
                         stderr=subprocess.DEVNULL)
            print(f"Unlock command executed: {self.unlock_cmd}")
        except FileNotFoundError:
            print(f"Error: Command not found: {self.unlock_cmd}")
        except Exception as e:
            print(f"Error executing unlock command: {e}")

    def closeEvent(self, event):
        # Make sure to clean up when closing
        if self.process and self.process.poll() is None:
            self.process.terminate()
            self.process.wait()
        event.accept()

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
        print("  padlock.py --lock-cmd 'your-vpn-client' --unlock-cmd 'pkill your-vpn-client'")
        sys.exit(1)

    app = QApplication(sys.argv)

    # Create and show the padlock toggle
    padlock = PadlockToggle(args.lock_cmd, args.unlock_cmd)
    padlock.show()

    sys.exit(app.exec_())

if __name__ == '__main__':
    main()
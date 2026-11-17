#!/bin/bash
# Removes TP Classroom Student from this Mac.
#   sudo ./uninstall-student.sh
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
  echo "Please run with sudo:  sudo $0"
  exit 1
fi

APP="/Applications/TP Classroom Student.app"
LABEL="com.tpclassroom.student"
EXE="TPClassroomStudent"
if [ -f "$APP/Contents/Info.plist" ]; then
  LABEL="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist")"
  EXE="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$APP/Contents/Info.plist")"
fi

CONSOLE_USER="$(stat -f%Su /dev/console)"
if [ "$CONSOLE_USER" != "root" ] && [ "$CONSOLE_USER" != "loginwindow" ]; then
  launchctl bootout "gui/$(id -u "$CONSOLE_USER")/$LABEL" 2>/dev/null || true
fi
pkill -x "$EXE" 2>/dev/null || true

rm -f "/Library/LaunchAgents/$LABEL.plist"
rm -rf "$APP"
rm -rf "/Library/Application Support/TPClassroom"
rm -f /etc/sudoers.d/tpclassroom

echo "✅ TP Classroom Student was removed."
echo "   You can also turn it off in System Settings → Privacy & Security (Screen Recording, Accessibility)."

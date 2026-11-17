#!/bin/bash
# Installs TP Classroom Student on this Mac for EVERY user account. It starts at login, keeps running in
# the background (macOS restarts it if it's quit), and can be updated by the teacher even when students
# use standard (non-admin) accounts.
#
#   sudo ./install-student.sh CLASSCODE [ADMIN_PIN]
#
# Easiest: open TP Classroom Student from the DMG and click "Install for All Users on This Mac"
# (it runs this script for you after asking for an administrator password).
# For many Macs (Apple Remote Desktop, MDM, Terminal): put this script next to
# "TP Classroom Student.app", or set APP_SOURCE to the app's path.
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
  echo "Please run with sudo:  sudo $0 CLASSCODE [ADMIN_PIN]"
  exit 1
fi

CLASS_CODE="${1:-}"
ADMIN_PIN="${2:-}"
if [ -z "$CLASS_CODE" ]; then
  echo "Usage: sudo $0 CLASSCODE [ADMIN_PIN]"
  exit 1
fi
if ! [[ "$CLASS_CODE" =~ ^[A-Za-z0-9_-]+$ ]]; then
  echo "The class code may only use letters, numbers, - and _"
  exit 1
fi
if [ -n "$ADMIN_PIN" ] && ! [[ "$ADMIN_PIN" =~ ^[A-Za-z0-9]+$ ]]; then
  echo "The admin PIN may only use letters and numbers"
  exit 1
fi

HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="${APP_SOURCE:-$HERE/TP Classroom Student.app}"
APP="/Applications/TP Classroom Student.app"
if [ ! -d "$SRC" ]; then
  echo "Can't find $SRC"
  exit 1
fi

LABEL="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$SRC/Contents/Info.plist")"
EXE="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$SRC/Contents/Info.plist")"
PLIST="/Library/LaunchAgents/$LABEL.plist"
CONSOLE_USER="$(stat -f%Su /dev/console)"

echo "▸ Stopping any running copy…"
if [ "$CONSOLE_USER" != "root" ] && [ "$CONSOLE_USER" != "loginwindow" ]; then
  launchctl bootout "gui/$(id -u "$CONSOLE_USER")/$LABEL" 2>/dev/null || true
fi
pkill -x "$EXE" 2>/dev/null || true
sleep 1

SRC_REAL="$(cd "$SRC" && pwd -P)"
APP_REAL="$(cd "$APP" 2>/dev/null && pwd -P || true)"
if [ "$SRC_REAL" != "$APP_REAL" ]; then
  echo "▸ Copying the app to /Applications…"
  rm -rf "$APP"
  ditto "$SRC" "$APP"
fi
xattr -dr com.apple.quarantine "$APP" 2>/dev/null || true
# Group "staff" (every local user) may write to the app, so its built-in updater works.
chown -R root:staff "$APP"
chmod -R g+w "$APP"

echo "▸ Saving the class settings…"
CONF_DIR="/Library/Application Support/TPClassroom"
mkdir -p "$CONF_DIR"
CODE_UPPER="$(printf '%s' "$CLASS_CODE" | tr '[:lower:]' '[:upper:]')"
if [ -n "$ADMIN_PIN" ]; then
  PIN_HASH="$(printf '%s' "$ADMIN_PIN" | shasum -a 256 | awk '{print $1}')"
  printf '{"classCode":"%s","adminPINHash":"%s"}\n' "$CODE_UPPER" "$PIN_HASH" > "$CONF_DIR/student.json"
else
  printf '{"classCode":"%s"}\n' "$CODE_UPPER" > "$CONF_DIR/student.json"
fi
chown root:wheel "$CONF_DIR/student.json"
chmod 644 "$CONF_DIR/student.json"

echo "▸ Letting the teacher shut down or restart this Mac…"
# Only these two exact commands, without a password (students can already shut down from the Apple menu).
SUDOERS_TMP="$(mktemp)"
printf '%%staff ALL=(root) NOPASSWD: /sbin/shutdown -h now, /sbin/shutdown -r now\n' > "$SUDOERS_TMP"
if visudo -cf "$SUDOERS_TMP" >/dev/null 2>&1; then
  install -m 440 -o root -g wheel "$SUDOERS_TMP" /etc/sudoers.d/tpclassroom
else
  echo "   (skipped: couldn't check the sudo rule)"
fi
rm -f "$SUDOERS_TMP"

echo "▸ Starting it automatically for every user at login…"
cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>$APP/Contents/MacOS/$EXE</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>LimitLoadToSessionType</key>
  <string>Aqua</string>
  <key>ProcessType</key>
  <string>Interactive</string>
</dict>
</plist>
EOF
chown root:wheel "$PLIST"
chmod 644 "$PLIST"

if [ "$CONSOLE_USER" != "root" ] && [ "$CONSOLE_USER" != "loginwindow" ]; then
  launchctl bootstrap "gui/$(id -u "$CONSOLE_USER")" "$PLIST" 2>/dev/null \
    || launchctl kickstart -k "gui/$(id -u "$CONSOLE_USER")/$LABEL" 2>/dev/null || true
fi

echo
echo "✅ TP Classroom Student is installed with class code $CODE_UPPER."
echo
echo "One more step on this Mac (needs an admin password, only once):"
echo "  System Settings → Privacy & Security →"
echo "    • Screen Recording  → turn on TP Classroom Student"
echo "    • Accessibility     → turn on TP Classroom Student"
echo "  Then log out and back in (or restart)."

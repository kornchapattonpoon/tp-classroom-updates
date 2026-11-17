#!/bin/bash
# Builds everything on your Mac, all with the same version number:
#
#   dist/TP-Classroom-<version>.dmg           → for Macs (teacher app + student app)
#   dist/TP-Classroom-Setup-<version>.exe     → for Windows PCs (one file: installs the teacher or student app)
#
# plus dist/update-files/ (used by scripts/release.sh) and dist/apps/ (the .app bundles, for testing).
#
# Needs: Xcode or the Command Line Tools (xcode-select --install)
#        (the .NET 10 SDK for Windows is downloaded into ~/.dotnet automatically).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
# shellcheck source=/dev/null
source "$ROOT/config.env"

ARCHS="${ARCHS:-arm64 x86_64}"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
BUILD_WINDOWS="${BUILD_WINDOWS:-auto}"
MIN_MACOS="13.0"
DIST="$ROOT/dist"
APPS="$DIST/apps"
UPDATES="$DIST/update-files"
WORK="$DIST/.work"
KEY="${UPDATE_PRIVATE_KEY:-$HOME/.tpclassroom/update_private_key}"
DMG="$DIST/TP-Classroom-$APP_VERSION.dmg"
SETUP_EXE="$DIST/TP-Classroom-Setup-$APP_VERSION.exe"

if ! xcrun --find swift >/dev/null 2>&1; then
  echo "Apple's build tools aren't installed. Run:  xcode-select --install"
  echo "(Installing them needs an admin password once. Without admin, ask whoever manages this Mac,"
  echo " or install Xcode from the App Store.)"
  exit 1
fi

# Automatic updates are always on: the first build makes your update-signing key by itself.
if [ -z "${UPDATE_PUBLIC_KEY:-}" ] || [ ! -f "$KEY" ]; then
  echo "▸ First build: making your update key so automatic updates work…"
  "$ROOT/scripts/setup-keys.sh"
  # shellcheck source=/dev/null
  source "$ROOT/config.env"
fi
CAN_SIGN=1
if [ -z "${UPDATE_PUBLIC_KEY:-}" ] || [ ! -f "$KEY" ]; then
  CAN_SIGN=0
  echo "⚠️  The update key couldn't be made, so these apps can't update. Run ./scripts/setup-keys.sh to see why."
fi
if [[ "${UPDATE_FEED_URL:-}" == *YOUR_GITHUB_NAME* ]]; then
  echo "⚠️  GITHUB_REPO in config.env isn't set, so apps can't find updates."
fi

# The Windows app needs Microsoft's free .NET 10 SDK. If it's missing, it's downloaded into
# ~/.dotnet — no Homebrew, no admin password needed.
WANT_WINDOWS=0
DOTNET=""
has_dotnet10() { [ -n "$1" ] && "$1" --list-sdks 2>/dev/null | grep -q '^10\.'; }
if [ "$BUILD_WINDOWS" != "no" ]; then
  for candidate in "$(command -v dotnet 2>/dev/null || true)" "$HOME/.dotnet/dotnet"; do
    if has_dotnet10 "$candidate"; then DOTNET="$candidate"; break; fi
  done
  if [ -z "$DOTNET" ]; then
    echo "▸ Downloading Microsoft's .NET 10 SDK into ~/.dotnet (once, about 200 MB)…"
    if curl -fsSL https://dot.net/v1/dotnet-install.sh -o "$ROOT/.dotnet-install.sh" &&
       bash "$ROOT/.dotnet-install.sh" --channel 10.0 --install-dir "$HOME/.dotnet" >/dev/null; then
      DOTNET="$HOME/.dotnet/dotnet"
    fi
    rm -f "$ROOT/.dotnet-install.sh"
  fi
  if has_dotnet10 "$DOTNET"; then
    WANT_WINDOWS=1
    export DOTNET_ROOT="$(dirname "$DOTNET")" DOTNET_CLI_TELEMETRY_OPTOUT=1 DOTNET_NOLOGO=1
  elif [ "$BUILD_WINDOWS" = "yes" ]; then
    echo "The .NET 10 SDK couldn't be downloaded. Check the internet connection and try again."
    exit 1
  else
    echo "⚠️  Skipping Windows: the .NET 10 SDK couldn't be downloaded (no internet?)."
  fi
fi

rm -rf "$DIST"
mkdir -p "$APPS" "$UPDATES" "$WORK"

# ---------------------------------------------------------------- Compile the Mac apps
BIN_DIRS=()
for ARCH in $ARCHS; do
  TRIPLE="$ARCH-apple-macosx$MIN_MACOS"
  echo "▸ Compiling Mac apps for ${ARCH}…"
  swift build -c release --triple "$TRIPLE" --scratch-path "$ROOT/.build/$ARCH"
  BIN_DIRS+=("$(swift build -c release --triple "$TRIPLE" --scratch-path "$ROOT/.build/$ARCH" --show-bin-path)")
done

swift build -c release --product TPCRelease >/dev/null
TOOL="$(swift build -c release --show-bin-path)/TPCRelease"

# The TP AI key from config.env, scrambled so it isn't plain text inside the apps.
AI_KEY_X=""
if [ -n "${AI_API_KEY:-}" ]; then
  AI_KEY_X="$("$TOOL" obfuscate --text "$AI_API_KEY")"
  echo "▸ TP AI key will be built into the teacher apps"
fi

make_icon() {
  local src="$1" out="$2"
  [ -f "$src" ] || return 0
  local tmp
  tmp="$(mktemp -d)"
  local iconset="$tmp/AppIcon.iconset"
  mkdir -p "$iconset"
  for size in 16 32 128 256 512; do
    sips -z "$size" "$size" "$src" --out "$iconset/icon_${size}x${size}.png" >/dev/null
    sips -z $((size * 2)) $((size * 2)) "$src" --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
  done
  iconutil -c icns "$iconset" -o "$out"
  rm -rf "$tmp"
}

codesign_item() {
  local item="$1"
  if [ "$SIGN_IDENTITY" = "-" ]; then
    codesign --force --sign - "$item"
  elif [[ "$SIGN_IDENTITY" == Developer\ ID* ]]; then
    codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$item"
  else
    codesign --force --sign "$SIGN_IDENTITY" "$item"
  fi
}

# assemble_app "<App Name>" <executable> <bundle id> <Info.plist template> <icon png>
assemble_app() {
  local name="$1" exe="$2" bundle_id="$3" plist_template="$4" icon="$5"
  local app="$APPS/$name.app"
  echo "▸ Packaging $name.app…"
  mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
  local inputs=()
  local dir
  for dir in "${BIN_DIRS[@]}"; do inputs+=("$dir/$exe"); done
  lipo -create "${inputs[@]}" -output "$app/Contents/MacOS/$exe"

  local info="$app/Contents/Info.plist"
  cp "$plist_template" "$info"
  plutil -replace CFBundleIdentifier -string "$bundle_id" "$info"
  plutil -replace CFBundleShortVersionString -string "$APP_VERSION" "$info"
  plutil -replace CFBundleVersion -string "$APP_VERSION" "$info"
  plutil -replace TPCUpdateFeedURL -string "${UPDATE_FEED_URL:-}" "$info"
  plutil -replace TPCUpdatePublicKey -string "${UPDATE_PUBLIC_KEY:-}" "$info"
  plutil -lint "$info" >/dev/null
  printf 'APPL????' > "$app/Contents/PkgInfo"
  make_icon "$icon" "$app/Contents/Resources/AppIcon.icns"
}

# ---------------------------------------------------------------- 1. Mac student app
STUDENT_APP="$APPS/TP Classroom Student.app"
assemble_app "TP Classroom Student" TPClassroomStudent "$BUNDLE_ID_PREFIX.student" \
  "$ROOT/Resources/Student-Info.plist" "$ROOT/Resources/StudentIcon.png"
cp "$ROOT/scripts/install-student.sh" "$STUDENT_APP/Contents/Resources/install-student.sh"
chmod +x "$STUDENT_APP/Contents/Resources/install-student.sh"
codesign_item "$STUDENT_APP"
(cd "$APPS" && ditto -c -k --keepParent "TP Classroom Student.app" "$WORK/student-mac.zip")
if [ "$CAN_SIGN" = "1" ]; then
  "$TOOL" sign-package --file "$WORK/student-mac.zip" --platform mac --version "$APP_VERSION" \
    --out "$WORK/student-mac.zip.json" --key "$KEY" >/dev/null
fi

# ---------------------------------------------------------------- 2. Windows app (one exe)
WINDOWS_BUILT=0
if [ "$WANT_WINDOWS" = "1" ]; then
  echo "▸ Compiling the Windows app…"
  "$DOTNET" publish "$ROOT/windows/TPClassroom.Windows/TPClassroom.Windows.csproj" -c Release \
    -o "$WORK/windows" \
    -p:Version="$APP_VERSION" \
    -p:UpdateFeedUrl="${UPDATE_FEED_URL:-}" \
    -p:UpdatePublicKey="${UPDATE_PUBLIC_KEY:-}" \
    -p:AiKeyX="$AI_KEY_X" \
    -p:AiModel="${AI_MODEL:-qwen/qwen3.8-27b}" \
    -p:AiBaseUrl="${AI_BASE_URL:-https://api.groq.com/openai/v1}" \
    -p:MacStudentPackageDir="$WORK" \
    -nologo -v:minimal
  if [ "$CAN_SIGN" = "1" ]; then
    # The setup exe = the app with its signature stored at the end (it installs itself when opened).
    "$TOOL" sign-windows --file "$WORK/windows/TPClassroom.exe" --version "$APP_VERSION" \
      --out "$SETUP_EXE" --json "$WORK/TPClassroom.exe.json" --key "$KEY" >/dev/null
  else
    cp "$WORK/windows/TPClassroom.exe" "$SETUP_EXE"
  fi
  WINDOWS_BUILT=1
  echo "▸ Made $(basename "$SETUP_EXE")"
fi

# ---------------------------------------------------------------- 3. Mac teacher app
TEACHER_APP="$APPS/TP Classroom.app"
assemble_app "TP Classroom" TPClassroomTeacher "$BUNDLE_ID_PREFIX.teacher" \
  "$ROOT/Resources/Teacher-Info.plist" "$ROOT/Resources/TeacherIcon.png"
# TP AI settings go into the teacher app only (never the student app).
TEACHER_INFO="$TEACHER_APP/Contents/Info.plist"
plutil -replace TPCAIKeyX -string "$AI_KEY_X" "$TEACHER_INFO"
plutil -replace TPCAIModel -string "${AI_MODEL:-qwen/qwen3.8-27b}" "$TEACHER_INFO"
plutil -replace TPCAIBaseURL -string "${AI_BASE_URL:-https://api.groq.com/openai/v1}" "$TEACHER_INFO"
plutil -lint "$TEACHER_INFO" >/dev/null
# The teacher carries both student apps, so it can update students without internet.
TEACHER_PACKAGES="$TEACHER_APP/Contents/Resources/Packages"
mkdir -p "$TEACHER_PACKAGES"
cp "$WORK/student-mac.zip" "$TEACHER_PACKAGES/"
[ -f "$WORK/student-mac.zip.json" ] && cp "$WORK/student-mac.zip.json" "$TEACHER_PACKAGES/"
if [ "$WINDOWS_BUILT" = "1" ]; then
  cp "$WORK/windows/TPClassroom.exe" "$TEACHER_PACKAGES/"
  [ -f "$WORK/TPClassroom.exe.json" ] && cp "$WORK/TPClassroom.exe.json" "$TEACHER_PACKAGES/"
fi
codesign_item "$TEACHER_APP"
(cd "$APPS" && ditto -c -k --keepParent "TP Classroom.app" "$UPDATES/TP-Classroom-Teacher-mac-$APP_VERSION.zip")

# ---------------------------------------------------------------- 4. DMG
echo "▸ Making $(basename "$DMG")…"
DMG_FOLDER="$WORK/dmg/TP Classroom"
mkdir -p "$DMG_FOLDER"
ditto "$TEACHER_APP" "$DMG_FOLDER/TP Classroom.app"
ditto "$STUDENT_APP" "$DMG_FOLDER/TP Classroom Student.app"
ln -s /Applications "$DMG_FOLDER/Applications"
cp "$ROOT/Resources/DMG-ReadMe.txt" "$DMG_FOLDER/Read Me First.txt"
for attempt in 1 2 3; do
  if hdiutil create -volname "TP Classroom $APP_VERSION" -srcfolder "$DMG_FOLDER" -fs HFS+ \
       -format UDZO -imagekey zlib-level=9 -ov "$DMG" >/dev/null; then
    break
  fi
  [ "$attempt" = 3 ] && { echo "Couldn't make the .dmg"; exit 1; }
  echo "▸ Making the .dmg failed, trying again…"
  sleep 5
done
if [ "$SIGN_IDENTITY" != "-" ]; then codesign --force --sign "$SIGN_IDENTITY" "$DMG"; fi

# ---------------------------------------------------------------- Extras
mkdir -p "$DIST/extras"
cp "$ROOT/scripts/install-student.sh" "$ROOT/scripts/uninstall-student.sh" "$DIST/extras/"
chmod +x "$DIST/extras/"*.sh
rm -rf "$WORK"

echo
echo "✅ Built version $APP_VERSION"
echo "   Mac:     dist/$(basename "$DMG")"
if [ "$WINDOWS_BUILT" = "1" ]; then
  echo "   Windows: dist/$(basename "$SETUP_EXE")"
else
  echo "   Windows: (skipped — install the .NET SDK to build it)"
fi

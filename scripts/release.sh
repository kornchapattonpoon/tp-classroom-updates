#!/bin/bash
# Builds, signs and publishes a new version of everything (Mac + Windows, same version).
#
#   1. Raise APP_VERSION in config.env (e.g. 1.0.0 → 1.0.1)
#   2. PUBLISH=1 ./scripts/release.sh "What's new in this version"
#
# Teacher apps download the new version when they're online. Every student computer then
# gets the same version from the teacher over the local network (no internet needed).
# The release page also has the .dmg and Setup .exe for installing on new computers.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
# shellcheck source=/dev/null
source "$ROOT/config.env"

NOTES="${1:-}"
KEY="${UPDATE_PRIVATE_KEY:-$HOME/.tpclassroom/update_private_key}"

if [ ! -f "$KEY" ] || [ -z "${UPDATE_PUBLIC_KEY:-}" ]; then
  "$ROOT/scripts/setup-keys.sh"
  # shellcheck source=/dev/null
  source "$ROOT/config.env"
fi
# PUBLISH=1 uploads with GitHub's own "gh" tool. If it's missing, it's downloaded into
# ~/.tpclassroom/tools — no Homebrew, no admin password needed.
GH="$(command -v gh 2>/dev/null || true)"
TOOLS="$HOME/.tpclassroom/tools"
[ -z "$GH" ] && [ -x "$TOOLS/gh" ] && GH="$TOOLS/gh"
if [ "${PUBLISH:-0}" = "1" ]; then
  if [ -z "$GH" ]; then
    echo "▸ Downloading GitHub's gh tool into $TOOLS (once)…"
    case "$(uname -m)" in arm64) GH_ARCH="arm64" ;; *) GH_ARCH="amd64" ;; esac
    GH_URL="$(curl -fsSL https://api.github.com/repos/cli/cli/releases/latest |
      grep -o "https://[^\"]*_macOS_${GH_ARCH}\.zip" | head -1)"
    if [ -z "$GH_URL" ]; then
      echo "Couldn't find the gh download. Check the internet connection and try again."
      exit 1
    fi
    GH_TMP="$(mktemp -d)"
    curl -fsSL "$GH_URL" -o "$GH_TMP/gh.zip"
    ditto -x -k "$GH_TMP/gh.zip" "$GH_TMP"
    mkdir -p "$TOOLS"
    cp "$(find "$GH_TMP" -path '*/bin/gh' -type f | head -1)" "$TOOLS/gh"
    chmod +x "$TOOLS/gh"
    rm -rf "$GH_TMP"
    GH="$TOOLS/gh"
  fi
  if ! "$GH" auth status --hostname github.com >/dev/null 2>&1; then
    echo "▸ Sign in to GitHub (once). Choose: GitHub.com → HTTPS → Login with a web browser."
    "$GH" auth login --hostname github.com --git-protocol https --web
  fi
fi
if [[ "$UPDATE_FEED_URL" == *YOUR_GITHUB_NAME* ]]; then
  echo "Set GITHUB_REPO in config.env first (e.g. tonpoon/tp-classroom-updates)."
  exit 1
fi

"$ROOT/scripts/build.sh"

TOOL="$(swift build -c release --show-bin-path)/TPCRelease"
DMG="$ROOT/dist/TP-Classroom-$APP_VERSION.dmg"
SETUP_EXE="$ROOT/dist/TP-Classroom-Setup-$APP_VERSION.exe"
TEACHER_ZIP="$ROOT/dist/update-files/TP-Classroom-Teacher-mac-$APP_VERSION.zip"
FEED="$ROOT/dist/update-files/appcast.json"

ASSETS=(--asset "mac-teacher=$TEACHER_ZIP")
UPLOADS=("$DMG" "$TEACHER_ZIP")
if [ -f "$SETUP_EXE" ]; then
  ASSETS+=(--asset "windows=$SETUP_EXE")
  UPLOADS+=("$SETUP_EXE")
else
  echo "⚠️  No Windows build in this release, so Windows teacher apps won't see it."
fi

echo "▸ Signing the update feed…"
"$TOOL" feed \
  --version "$APP_VERSION" \
  --asset-base-url "$ASSET_BASE_URL" \
  "${ASSETS[@]}" \
  --key "$KEY" \
  --expect-public-key "$UPDATE_PUBLIC_KEY" \
  --notes "$NOTES" \
  --min-macos 13.0 \
  --out "$FEED"
UPLOADS+=("$FEED")

if [ "${PUBLISH:-0}" = "1" ]; then
  echo "▸ Publishing release v$APP_VERSION to ${GITHUB_REPO}…"
  "$GH" release create "v$APP_VERSION" "${UPLOADS[@]}" \
    --repo "$GITHUB_REPO" --title "TP Classroom $APP_VERSION" --notes "${NOTES:-TP Classroom $APP_VERSION}"
  echo "✅ Published. Teacher apps update within a couple of hours, then update every student."
else
  echo
  echo "✅ Release $APP_VERSION is ready. Create a GitHub release named v$APP_VERSION at"
  echo "   https://github.com/$GITHUB_REPO/releases/new and attach these files:"
  for file in "${UPLOADS[@]}"; do echo "     ${file#"$ROOT/"}"; done
  echo "   (Or run again with PUBLISH=1 to upload automatically with the GitHub CLI.)"
fi

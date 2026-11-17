#!/bin/bash
# One-time setup: creates your update-signing key and saves the public half in config.env.
# The private key stays on your Mac (~/.tpclassroom/update_private_key). Back it up and never share it:
# without it you can't publish updates that already-installed apps will accept.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
KEY="${UPDATE_PRIVATE_KEY:-$HOME/.tpclassroom/update_private_key}"

echo "▸ Building the release tool…"
swift build -c release --product TPCRelease
TOOL="$(swift build -c release --show-bin-path)/TPCRelease"

if [ -f "$KEY" ]; then
  echo "▸ Using your existing key at $KEY"
else
  "$TOOL" keygen --out "$KEY" >/dev/null
  echo "▸ Created a new private key at $KEY — back it up somewhere safe!"
fi

PUBLIC_KEY="$("$TOOL" pubkey --key "$KEY")"
sed -i '' "s|^UPDATE_PUBLIC_KEY=.*|UPDATE_PUBLIC_KEY=\"$PUBLIC_KEY\"|" "$ROOT/config.env"
echo "▸ Saved the public key in config.env"
echo
echo "Back up $KEY somewhere safe (e.g. a USB drive). Without it you can't publish updates."

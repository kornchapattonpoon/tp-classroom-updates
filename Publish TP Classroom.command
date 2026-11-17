#!/bin/bash
# Double-click this file to build TP Classroom and publish it on GitHub.
# Every installed teacher app then updates itself, and gives the same version to every student.
cd "$(dirname "$0")" || exit 1
VERSION="$(sed -n 's/^APP_VERSION="\(.*\)"/\1/p' config.env)"
echo "=============================================="
echo "  TP Classroom $VERSION: build and publish"
echo "=============================================="
echo
echo "This downloads (once, into your home folder, no admin needed):"
echo "  - Microsoft's .NET SDK, about 200 MB, to build the Windows app"
echo "  - GitHub's gh tool, about 14 MB, to publish"
echo "Then it builds the Mac and Windows apps and publishes version $VERSION to"
echo "github.com/kornchapattonpoon/tp-classroom-updates"
echo
read -r -p "What's new in version $VERSION? (or just press Return): " NOTES
echo
PUBLISH=1 ./scripts/release.sh "${NOTES:-TP Classroom $VERSION}"
STATUS=$?
echo
if [ "$STATUS" -eq 0 ]; then
  echo "All done. Install the apps from the dist folder; from now on they update themselves."
  open "$(pwd)/dist" 2>/dev/null
else
  echo "Something went wrong. Copy the text above and send it to Claude."
fi
echo
read -n 1 -s -r -p "Press any key to close this window."

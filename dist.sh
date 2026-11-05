#!/usr/bin/env bash
#
# dist.sh — builds the release file, dist/lumignon.plasmoid: the widget, its
# French catalog compiled. It installs offline: right-click a panel, Add Widgets…,
# Get New…, Install Widget From Local File; or kpackagetool6 -t Plasma/Applet -i <file>.

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"
ID="com.github.elomkdn.lumignon"
rm -rf dist
mkdir -p dist/package
cp -r package/. dist/package/
find dist/package -name __pycache__ -prune -exec rm -rf {} +
mkdir -p dist/package/contents/locale/fr/LC_MESSAGES
msgfmt -o "dist/package/contents/locale/fr/LC_MESSAGES/plasma_applet_$ID.mo" po/fr.po
python3 -I -c 'import shutil, sys; shutil.make_archive(sys.argv[1], "zip", sys.argv[2])' \
  dist/lumignon dist/package
mv dist/lumignon.zip dist/lumignon.plasmoid
rm -rf dist/package
echo dist/lumignon.plasmoid

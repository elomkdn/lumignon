#!/usr/bin/env bash
#
# install.sh — installs or updates the Lumignon widget for your user
#
# Usage:
#   ./install.sh               install, or update in place
#   ./install.sh --uninstall   remove it
#
# Then add it to a panel (right-click the panel, Add Widgets, Lumignon). After an update,
# log out and back in, or run: systemctl --user restart plasma-plasmashell

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"
ID="com.github.elomkdn.lumignon"

if [[ "${1:-}" == "--uninstall" || "${1:-}" == "-u" ]]; then
  kpackagetool6 -t Plasma/Applet -r "$ID"
  exit 0
fi

# the French catalog, from po/fr.po
if command -v msgfmt >/dev/null; then
  mkdir -p package/contents/locale/fr/LC_MESSAGES
  msgfmt -o "package/contents/locale/fr/LC_MESSAGES/plasma_applet_$ID.mo" po/fr.po
fi

if kpackagetool6 -t Plasma/Applet -s "$ID" >/dev/null 2>&1; then
  kpackagetool6 -t Plasma/Applet -u package
else
  kpackagetool6 -t Plasma/Applet -i package
fi

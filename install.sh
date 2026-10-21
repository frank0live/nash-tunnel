#!/usr/bin/env bash
# Nash Tunnel one-line installer.
#   curl -fsSL https://raw.githubusercontent.com/<user>/nash-tunnel/main/install.sh | bash
set -euo pipefail

REPO="${NASH_REPO:-https://github.com/frank0live/nash-tunnel.git}"
DEST="${NASH_DIR:-/opt/nash-tunnel}"

[[ ${EUID:-$(id -u)} -eq 0 ]] || { echo "run as root" >&2; exit 1; }

command -v git >/dev/null 2>&1 || {
  if command -v apt-get >/dev/null; then apt-get update -qq && apt-get install -y -qq git
  elif command -v dnf >/dev/null; then dnf install -y -q git
  fi
}

if [[ -d "$DEST/.git" ]]; then
  echo "→ updating $DEST"
  git -C "$DEST" pull --ff-only
else
  echo "→ cloning into $DEST"
  rm -rf "$DEST"
  git clone --depth 1 "$REPO" "$DEST"
fi

cd "$DEST"
chmod +x nash.sh
exec bash nash.sh

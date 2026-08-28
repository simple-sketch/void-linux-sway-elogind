#!/bin/sh

# Optional Nerd Fonts collection. This is kept out of the main desktop install
# because the nerd-fonts package is a large download and installation.

set -eu

command -v sudo >/dev/null 2>&1 || {
  echo "sudo is required" >&2
  exit 1
}

sudo -v
sudo xbps-install -Sy nerd-fonts

echo "Nerd Fonts installed"

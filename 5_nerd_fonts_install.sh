#!/bin/sh

# Optional Nerd Fonts collection. This is kept out of the main desktop install
# because the nerd-fonts package is a large download and installation.

set -eu

sudo xbps-install -Sy nerd-fonts

echo "Nerd Fonts installed"

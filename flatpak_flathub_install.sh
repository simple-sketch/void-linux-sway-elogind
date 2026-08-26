#!/bin/sh

# Optional Flatpak applications. Kept separate from the main desktop install so
# Flatpak and the Flathub remote are only configured when wanted.

set -eu

# Install Flatpak and add the Flathub repository.
sudo xbps-install -Sy flatpak
sudo flatpak remote-add --if-not-exists flathub \
  https://dl.flathub.org/repo/flathub.flatpakrepo

# Install Keypunch from Flathub.
sudo flatpak --assumeyes install flathub no.bragefuglseth.Keypunch
sudo flatpak --assumeyes install flathub io.dbeaver.DBeaverCommunity
sudo flatpak --assumeyes install flathub com.getpostman.Postman

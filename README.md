# Void Linux Sway + Noctalia (elogind)

These scripts turn a plain Void Linux installation into an Intel Sway desktop
with Noctalia, PipeWire, and elogind. The main installer targets x86_64 glibc:
it enables multilib repositories and installs Intel graphics packages.

The desktop configuration lives in
[dotfiles-stow](https://github.com/simple-sketch/dotfiles-stow). The installer
clones that repository to `~/dotfiles-stow` and uses GNU Stow to symlink its
packages into the home directory.

## Prerequisites

- A working Void Linux network connection
- A normal user with configured `sudo` access
- An Intel GPU

Review the scripts and the machine-specific dotfiles before running them. The
main installer adds the third-party `https://repo.voiders.dev` XBPS repository,
installs packages, enables runit services, changes group membership, and moves
conflicting shell files into `~/.dotfiles-backup/`.

## Desktop install

Run the installer as your normal user, not directly as root:

```sh
./install.sh
sudo reboot
```

The script checks each runit service before continuing. A failed required
service stops the install instead of reporting a successful setup.

## Network choice

Use only one Wi-Fi manager.

For Noctalia's network widget, install NetworkManager:

```sh
./networkmanager_install.sh
```

This disables conflicting standalone services (`iwd`, `wpa_supplicant`,
`dhcpcd`, ConnMan, and Wicd). It starts D-Bus and polkit first, then restores
the prior network services if NetworkManager cannot start.

To use `iwctl` instead, install standalone iwd with dhcpcd:

```sh
./iwd.sh
```

The iwd script refuses conflicting network managers and an existing
`EnableNetworkConfiguration=true` setting because dhcpcd owns DHCP.

## Optional installs

```sh
./flatpak_flathub_install.sh  # Flathub, Keypunch, DBeaver, and Postman
./nerd_fonts_install.sh       # Large Nerd Fonts collection
./zramen_install.sh           # Compressed RAM swap
```

The zram configuration is `/etc/sv/zramen/conf`.

## Checks

Run syntax checks, ShellCheck (when installed), and sandboxed service setup and
rollback tests (when Bubblewrap is available):

```sh
./tests/check.sh
```

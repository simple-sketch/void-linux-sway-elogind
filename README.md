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

The script actively requests each required runit service to start and waits up
to 15 seconds for readiness. A failed service stops the install instead of
reporting a successful setup. Before package or service changes, the installer
also rejects conflicting managed configuration and verifies the existing PAM,
network-service, iwd, and dotfiles state.

The installer prints the expected Voiders signing fingerprint before repository
sync and verifies the active repository fingerprint afterward. The fingerprint
[published by the Voiders project](https://codeberg.org/voiders-community/repository)
is `a8:f0:05:df:01:c4:37:92:83:f6:8b:9a:ce:ab:73:29`.

## Network choice

The main installer configures standalone iwd with dhcpcd. It installs both
packages, starts and verifies dhcpcd, and only then removes the enabled
`wpa_supplicant` service link. If iwd does not start, the installer restores the
previous `wpa_supplicant` service. It refuses conflicting NetworkManager,
ConnMan, or Wicd services and an iwd `EnableNetworkConfiguration=true` setting.

To use Noctalia's NetworkManager integration instead, run:

```sh
./networkmanager_install.sh
```

This disables conflicting standalone services (`iwd`, `wpa_supplicant`,
`dhcpcd`, ConnMan, and Wicd). It starts D-Bus and polkit first, then restores
the prior network services if NetworkManager cannot start.

Run `networkmanager_install.sh` after the main installer if you want to replace
the integrated iwd setup.

## Optional installs

```sh
./flatpak_flathub_install.sh  # Flathub, Keypunch, DBeaver, and Postman
./nerd_fonts_install.sh       # Large Nerd Fonts collection
./zramen_install.sh           # Compressed RAM swap
```

The zram configuration is `/etc/sv/zramen/conf`.

## Checks

Run POSIX shell syntax checks, ShellCheck and shfmt checks (when installed), and
sandboxed installer preflight, service-ordering, repository-fingerprint, and
wireless-rollback tests (when Bubblewrap is available). The tests use mocked
`sudo` and XBPS commands and do not change host services or configuration:

```sh
./tests/check.sh
```

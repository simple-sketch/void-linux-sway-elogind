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

Run the installer as your normal user, not directly as root:

```sh
./install.sh
sudo reboot
```

## Optional installs

```sh
./flatpak_flathub_install.sh  # Flathub, Keypunch, DBeaver, and Postman


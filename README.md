# Void Linux SwayWM Noctalia 

Install scripts that take a plain Void Linux base image to a working sway
desktop on Wayland, with **elogind** as session, seat and power manager.

Configs are not in this repo. They live in
[dotfiles-stow](https://github.com/simple-sketch/dotfiles-stow), laid out as
GNU Stow packages, and are symlinked into `~` rather than copied, so editing
`~/.config/sway/config` *is* editing the repo.

## Install

Run the all-in-one installer as your normal user, not directly as root:

```sh
sh install.sh
sudo reboot
```

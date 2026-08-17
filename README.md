# void-linux-sway-elogind

Install scripts that take a plain Void Linux base image to a working sway
desktop on Wayland, with **elogind** as session, seat and power manager.

Configs are not in this repo. They live in
[dotfiles](https://github.com/simple-sketch/dotfiles), laid out as GNU stow
packages, and are symlinked into `~` rather than copied, so editing
`~/.config/sway/config` *is* editing the repo.

## Install

```sh
sh 1_alt_cli_tools_apps_sway_noctalia_install.sh
sudo reboot
git clone https://github.com/simple-sketch/dotfiles ~/dotfiles
cd ~/dotfiles && stow */
```

Then, optional:

```sh
sh 3_multimedia_install.sh   # audio and bluetooth
sh 4_iwd.sh                  # wifi, if you are not using NetworkManager
```

Log out and back in to **tty1**. `.bash_profile` starts sway from there, no
display manager involved.

## What the install script does

`1_alt_cli_tools_apps_sway_noctalia_install.sh` installs the packages, Intel
graphics, portals, socklog, dbus, elogind, polkit, noctalia, flatpak, tlp and
udisks2, and then prepares the home directory for the stow that follows:

- **creates `~/.config`, `~/.local/{share,state,bin}`, `~/Pictures/Screenshots`**
  — an existing directory is what makes stow descend into it and link the files
  inside, see the folding note below
- **moves the `/etc/skel` dotfiles aside** — `.bashrc`, `.bash_profile` and
  `.inputrc` go to `~/.dotfiles-backup/<timestamp>/`, because stow will not
  overwrite them and will not stow anything else while they are there
- **installs git**, which is not a `base-devel` dependency on Void

Re-running it is safe: it only moves regular files, so stow symlinks from an
earlier run are left alone.

## stow notes

**`stow */`, not `stow .`** — with a bare dot stow treats the whole repo as one
package and links `~/bashrc -> dotfiles/bashrc`, leaving you with no `~/.bashrc`
and no `~/.config` links at all. The trailing slash on the glob keeps `.git`
out. Run it from inside `~/dotfiles`; the default target is the parent
directory, which is `~`.

**`~/.config` has to exist first.** If it does not, stow *folds*: it makes
`~/.config` itself a symlink into whichever package it saw first, after which
every program on the machine writes its config into the dotfiles repo. One
level down is the opposite, `~/.config/sway` is *meant* to become a symlink to
the sway package.

**One conflict aborts everything.** stow will not overwrite a regular file it
does not own, and it stops the whole run on the first one, having linked
nothing. The three `/etc/skel` files are handled for you. For anything else it
reports:

```sh
mv ~/.config/foo/bar.toml ~/.dotfiles-backup/     # then stow again
```

Do not reach for `--adopt` to resolve a conflict. It imports the *system* file
into the repo and overwrites the version you wanted.

**Apps that rewrite their own config write into the repo**, because the
directory they write into is a symlink. That is usually the point, but it means
`git -C ~/dotfiles status` is where the surprise shows up.

## After the reboot

In this order, each one explains the next one's failure:

```sh
loginctl session-status        # session registered and active
ls -d /run/user/$(id -u)       # pam_elogind created XDG_RUNTIME_DIR
ls -l ~/.bashrc                # points into ~/dotfiles
less ~/.local/state/sway.log   # exists once sway has been started once
```

## Notes

Written for a plain Void base image on Intel graphics. Pick the elogind scripts
or the seatd/turnstile ones, never both: Void's `/etc/pam.d/system-login`
carries `pam_turnstile.so` and `pam_elogind.so` in the same session stack, each
prefixed with `-` so it is skipped while its package is absent, and installing
both leaves two things racing to own the session.

`1_cli_tools_apps_sway_noctalia_install.sh` and
`2_after_restart_env_prepare.sh` are the scripted alternative to the above:
script 2 clones the dotfiles repo and stows it for you. Run that pair or
`1_alt_`, never both, and note they carry the same package list, so a package
added to one has to be added to the other.

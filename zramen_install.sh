#!/bin/sh

# Optional zram swap. Kept out of the main desktop install because whether a
# compressed swap device in RAM is worth it depends on the machine: it helps on
# a low memory laptop, and on a box with plenty of RAM and a real swap
# partition it only spends CPU on compression.
#
# zramen is Void's zram manager. The service creates the device on boot
# ("zramen make") and removes it on shutdown ("zramen toss"). Size, priority
# and compression algorithm are set in /etc/sv/zramen/conf, which ships with
# the defaults commented out, so edit that file rather than this script.

set -eu

sudo xbps-install -Sy zramen
sudo ln -sfn /etc/sv/zramen /var/service/

# wait for runsvdir to pick the service up instead of guessing at a sleep
i=0
while [ "$i" -lt 10 ]; do
  sudo sv check zramen >/dev/null 2>&1 && break
  i=$((i + 1))
  sleep 1
done

sudo sv status zramen || echo "warning: zramen did not come up" >&2

echo "zram swap enabled, tune it in /etc/sv/zramen/conf"
echo "check the device with: zramctl"
echo "and the swap priorities with: swapon --show"

#!/bin/sh

set -eu

# Division of labour: iwd only does association. IP configuration stays with
# dhcpcd, which Void enables by default and which also covers ethernet. That is
# why /etc/iwd/main.conf is deliberately not written here - setting
# EnableNetworkConfiguration=true would give iwd its own DHCP client and the two
# would fight over the interface.

# 0. Only one daemon can own the wireless hardware. NetworkManager would fight
#    iwd for it, so refuse rather than half-configure the machine.
if [ -e /var/service/NetworkManager ]; then
	echo "NetworkManager service is enabled, it conflicts with iwd" >&2
	echo "disable it first: sudo rm /var/service/NetworkManager" >&2
	exit 1
fi

# 1. install iwd
sudo xbps-install -Sy iwd

# 2. Disable wpa_supplicant (if it was running/enabled) before iwd takes the interface
if [ -e /var/service/wpa_supplicant ]; then
	sudo sv down wpa_supplicant || true
	sudo rm -f /var/service/wpa_supplicant
fi

# 3. dhcpcd owns IP config. It is enabled on a default Void install, but do not
#    rely on that - without it, associating gets you no address.
if [ ! -e /var/service/dhcpcd ]; then
	echo "dhcpcd service was not enabled, enabling it for IP configuration"
	sudo xbps-install -Sy dhcpcd
	sudo ln -sfn /etc/sv/dhcpcd /var/service/
fi

# 4. enable iwd
sudo ln -sfn /etc/sv/iwd /var/service/

# wait for runsvdir to pick the services up instead of guessing at a sleep
i=0
while [ "$i" -lt 10 ]; do
	sudo sv check iwd >/dev/null 2>&1 &&
		sudo sv check dhcpcd >/dev/null 2>&1 && break
	i=$((i + 1))
	sleep 1
done

sudo sv status iwd || echo "warning: iwd did not come up" >&2
sudo sv status dhcpcd || echo "warning: dhcpcd did not come up" >&2

echo "iwd enabled, connect with: iwctl station wlan0 connect <SSID>"
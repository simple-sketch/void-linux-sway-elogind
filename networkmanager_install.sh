#!/bin/sh

set -eu

# NetworkManager exposes both ethernet and Wi-Fi over one D-Bus API, which is
# the backend Noctalia's network widget uses for scanning and connecting.
# iwd, wpa_supplicant and dhcpcd must not run as separate system services at
# the same time: NetworkManager starts its own Wi-Fi helper and handles DHCP.

# Install everything before stopping the current network services so an
# existing connection is kept for as long as possible.
sudo xbps-install -Sy NetworkManager iw

# Disable a conflicting runit service if it is enabled. Test -L as well as -e
# so a stale or broken service link is removed too.
disable_service() {
	service=$1
	if [ -e "/var/service/$service" ] || [ -L "/var/service/$service" ]; then
		echo "disabling conflicting service: $service"
		sudo sv down "$service" || true
		sudo rm -f "/var/service/$service"
	fi
}

disable_service iwd
disable_service wpa_supplicant
disable_service dhcpcd

# iwd can remove the managed interface when it exits. Normally the kernel
# recreates it at the next boot; create one now as well so this script works
# without a reboot. Existing managed interfaces are left untouched.
sudo rfkill unblock wifi || true

interface_index=0
for phy_path in /sys/class/ieee80211/phy*; do
	[ -d "$phy_path" ] || continue

	has_managed_interface=false
	for interface_path in "$phy_path"/device/net/*; do
		[ -e "$interface_path" ] || continue
		interface_name=${interface_path##*/}
		if iw dev "$interface_name" info 2>/dev/null | grep -q 'type managed'; then
			has_managed_interface=true
			break
		fi
	done

	[ "$has_managed_interface" = true ] && continue

	while ip link show "wlan$interface_index" >/dev/null 2>&1; do
		interface_index=$((interface_index + 1))
	done

	phy_name=${phy_path##*/}
	interface_name="wlan$interface_index"
	if sudo iw phy "$phy_name" interface add "$interface_name" type managed; then
		echo "restored Wi-Fi interface $interface_name on $phy_name"
	else
		echo "warning: could not restore an interface on $phy_name; reboot once after this script" >&2
	fi
	interface_index=$((interface_index + 1))
done

# Enable NetworkManager persistently and wait for runit and D-Bus to see it.
sudo ln -sfn /etc/sv/NetworkManager /var/service/

i=0
while [ "$i" -lt 15 ]; do
	if sudo sv check NetworkManager >/dev/null 2>&1 &&
		nmcli general status >/dev/null 2>&1; then
		break
	fi
	i=$((i + 1))
	sleep 1
done

sudo sv status NetworkManager || echo "warning: NetworkManager did not come up" >&2

if nmcli general status >/dev/null 2>&1; then
	sudo nmcli networking on
	sudo nmcli radio wifi on

	echo
	nmcli -f DEVICE,TYPE,STATE,CONNECTION device status
	echo
	echo "NetworkManager now provides ethernet and Wi-Fi to Noctalia."
	echo "Open Noctalia's network widget to scan and connect."
	echo "If Noctalia was already running with the iwd backend, log out and back in once."
else
	echo "warning: NetworkManager is not available on D-Bus; reboot and check: sudo sv status NetworkManager" >&2
	exit 1
fi

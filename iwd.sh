#!/bin/sh

set -eu

# Division of labour: iwd only does association. IP configuration stays with
# dhcpcd, which also covers ethernet. /etc/iwd/main.conf is deliberately not
# changed here: EnableNetworkConfiguration=true would give iwd its own DHCP
# client and make it compete with dhcpcd.

SERVICE_START_TIMEOUT=15
IWD_CONFIG_FILE=${IWD_CONFIG_FILE:-/etc/iwd/main.conf}
IWD_WAS_ENABLED=false
WPA_SUPPLICANT_WAS_ENABLED=false
ROLLBACK_REQUIRED=false

command -v sudo >/dev/null 2>&1 || {
  echo "sudo is required" >&2
  exit 1
}

sudo -v

service_is_enabled() {
  service_name=$1
  [ -e "/var/service/$service_name" ] || [ -L "/var/service/$service_name" ]
}

link_service() {
  service_name=$1
  service_source="/etc/sv/$service_name"
  service_target="/var/service/$service_name"

  if [ ! -d "$service_source" ]; then
    echo "service directory is missing: $service_source" >&2
    return 1
  fi

  if [ -e "$service_target" ] && [ ! -d "$service_target" ] && [ ! -L "$service_target" ]; then
    echo "cannot enable $service_name: $service_target is not a service directory or symlink" >&2
    return 1
  fi

  if [ ! -d "$service_target" ] || [ -L "$service_target" ]; then
    sudo ln -sfn "$service_source" "$service_target"
  fi
}

wait_for_service() {
  service_name=$1
  i=0

  while [ "$i" -lt "$SERVICE_START_TIMEOUT" ]; do
    if sudo sv check "$service_name" >/dev/null 2>&1; then
      return 0
    fi
    i=$((i + 1))
    sleep 1
  done

  sudo sv status "$service_name" >&2 || true
  return 1
}

restore_wpa_supplicant() {
  exit_status=$?
  trap - EXIT

  if [ "$ROLLBACK_REQUIRED" = true ]; then
    echo "iwd setup failed; restoring the previous wireless service" >&2

    if [ "$IWD_WAS_ENABLED" = false ]; then
      sudo sv down iwd >/dev/null 2>&1 || true
      if [ -L /var/service/iwd ]; then
        sudo rm -f /var/service/iwd ||
          echo "warning: could not remove the iwd service link" >&2
      fi
    fi

    if [ "$WPA_SUPPLICANT_WAS_ENABLED" = true ]; then
      if sudo ln -sfn /etc/sv/wpa_supplicant /var/service/wpa_supplicant; then
        sudo sv up wpa_supplicant >/dev/null 2>&1 ||
          echo "warning: restored wpa_supplicant but could not start it" >&2
      else
        echo "warning: could not restore the wpa_supplicant service link" >&2
      fi
    fi
  fi

  exit "$exit_status"
}

# Only one network manager can own the wireless hardware. Refuse rather than
# leave a half-configured machine. Test -L too so broken links are detected.
for network_manager in NetworkManager connmand wicd; do
  if service_is_enabled "$network_manager"; then
    echo "$network_manager is enabled and conflicts with standalone iwd" >&2
    echo "disable it first: sudo rm /var/service/$network_manager" >&2
    exit 1
  fi
done

if service_is_enabled wpa_supplicant && [ ! -L /var/service/wpa_supplicant ]; then
  echo "cannot switch wireless: /var/service/wpa_supplicant is not a removable symlink" >&2
  exit 1
fi

if [ -e /var/service/iwd ] && [ ! -d /var/service/iwd ] && [ ! -L /var/service/iwd ]; then
  echo "cannot enable iwd: /var/service/iwd is not a service directory or symlink" >&2
  exit 1
fi

if [ -r "$IWD_CONFIG_FILE" ] &&
  grep -Eiq '^[[:space:]]*EnableNetworkConfiguration[[:space:]]*=[[:space:]]*true([[:space:]]|$)' "$IWD_CONFIG_FILE"; then
  echo "cannot combine dhcpcd with EnableNetworkConfiguration=true in $IWD_CONFIG_FILE" >&2
  echo "disable iwd network configuration before running this script" >&2
  exit 1
fi

# Install all dependencies before stopping the current wireless service.
sudo xbps-install -Sy iwd dbus dhcpcd

# iwd exposes its control interface over the system bus, so prove D-Bus works
# before changing any wireless service.
link_service dbus
if ! wait_for_service dbus; then
  echo "error: D-Bus did not become ready; existing wireless was left unchanged" >&2
  exit 1
fi

# Bring up DHCP first. Associating without this service would leave both Wi-Fi
# and ethernet without address configuration.
link_service dhcpcd
if ! wait_for_service dhcpcd; then
  echo "error: dhcpcd did not become ready; existing wireless was left unchanged" >&2
  exit 1
fi

[ -d /var/service/iwd ] && IWD_WAS_ENABLED=true
[ -d /var/service/wpa_supplicant ] && WPA_SUPPLICANT_WAS_ENABLED=true
ROLLBACK_REQUIRED=true
trap restore_wpa_supplicant EXIT

if service_is_enabled wpa_supplicant; then
  sudo sv down wpa_supplicant || true
  sudo rm -f /var/service/wpa_supplicant
fi

link_service iwd
if ! wait_for_service iwd; then
  echo "error: iwd did not become ready" >&2
  exit 1
fi

sudo sv status iwd
sudo sv status dhcpcd

echo "iwd is enabled. List adapters with: sudo iwctl device list"
echo "Connect with: sudo iwctl station <device> connect <SSID>"

ROLLBACK_REQUIRED=false
trap - EXIT

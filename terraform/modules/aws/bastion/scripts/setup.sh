#!/bin/bash

set -xe

# Install fail2ban
sudo apt-get update
sudo apt-get install -y fail2ban

ORIG_CONF="/etc/fail2ban/jail.conf"
LOCAL_CONF="/etc/fail2ban/jail.local"

if [ -f "${ORIG_CONF}" ]; then
  # Configure fail2ban
  sudo cp "${ORIG_CONF}" "${LOCAL_CONF}"
  sudo sed -i 's/^bantime\s*= 10m$/bantime = 30m/' "${LOCAL_CONF}"
  sudo sed -i 's/^findtime\s*= 10m/findtime = 30m/' "${LOCAL_CONF}"
  sudo sed -i 's/maxretry\s*= 5/maxretry = 3/' "${LOCAL_CONF}"

  # Enable and Start fail2ban
  sudo systemctl enable --now fail2ban
else
  # If fail2ban is not on the sysytem, something has gone wrong
  echo "Fail2Ban was not found on the system! Exiting..."
fi

# Turn on automatic upgrades/reboots
UPGRADE_CONF_FILE="/etc/apt/apt.conf.d/50unattended-upgrades"

sudo cp $UPGRADE_CONF_FILE /tmp/unattended-upgrades.conf
sudo sed -i 's/\/\/\(\s*"\${distro_id}:\${distro_codename}-updates";\)/  \1/' "${UPGRADE_CONF_FILE}"
sudo sed -i 's/\/\/\(Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";\)/\1/' "${UPGRADE_CONF_FILE}"
sudo sed -i 's/\/\/\(Unattended-Upgrade::Automatic-Reboot \)"false";/\1 "true";/' "${UPGRADE_CONF_FILE}"
sudo sed -i 's/\/\/\(Unattended-Upgrade::Automatic-Reboot-Time \)"02:00";/\1 "07:00";/' "${UPGRADE_CONF_FILE}"
sudo sed -i 's/\/\/\(Unattended-Upgrade::Automatic-Reboot-WithUsers "true";\)/\1/' "${UPGRADE_CONF_FILE}"

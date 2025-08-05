#!/bin/bash
# =============================================================================
# Coral Edge TPU PCIe Driver Installation Script for Debian (trixie)
#
# This script installs and manages the Coral Edge TPU driver on Debian-based systems.
# It builds the driver from source using Google's official gasket-driver repository,
# applying updates from pull request #50 to support Linux kernel 6.13+.
#
# Features:
# - Installs required packages and TPU userspace library (libedgetpu1-std)
# - Builds and installs kernel modules via DKMS
# - Supports non-root access configuration 
# - Provides options to rebuild, reinstall, or uninstall the PCIe driver
#
# Usage: sudo ./install_coral_tpu.sh [--install|--reinstall|--rebuild|--uninstall|--status|--setup-non-root USER]

set -e

KEYRING="/etc/apt/keyrings/coral-edgetpu.gpg"
SOURCES="/etc/apt/sources.list.d/coral-edgetpu.list"
UDEV_RULE="/etc/udev/rules.d/65-apex.rules"

# Function to display usage
display_usage() {
    echo "Usage: sudo bash $0 [OPTION]"
    echo "Options:"
    echo "  --status        : Display installation status."
    echo "  --install       : Install the TPU driver and library."
    echo "  --uninstall     : Uninstall the TPU driver and library."
    echo "  --reinstall     : Reinstall the TPU driver from source."
    echo "  --rebuild       : Rebuild the TPU driver for the current kernel."
    echo "  --setup-non-root [username] : Set up non-root access for the specified user."
}

# Function to prompt for reboot
prompt_reboot() {
    read -p "Reboot is required to apply changes. Do you want to reboot now? (y/n): " choice
    case "$choice" in
        y|Y ) reboot ;;
        * ) echo "Please reboot manually later to apply changes." ;;
    esac
}

status() {
  status_failed=false

  # Check hardware detection
  if command -v lspci >/dev/null; then
      tpu_detect=$(lspci -nn | grep '1ac1:089a' || true)
      if [ -n "$tpu_detect" ]; then
          echo -e "Coral TPU PCIe hardware detected:\n$tpu_detect\n"
      else
          echo "Coral TPU PCIe hardware not detected (lspci | grep 1ac1:089a)."
          status_failed=true
      fi
  else
      echo "lspci not available, skipping hardware detection check."
  fi

  # Check device /dev/apex_0
  if [ -e /dev/apex_0 ]; then
      echo -e "Apex devices installed: \n$(ls /dev/apex_*)\n"
  else
      echo "Apex devices not found in /dev."
      status_failed=true
  fi

  # DKMS status for gasket
  dkms_gasket=$(dkms status | grep '^gasket/' || true)
  if [ -n "$dkms_gasket" ]; then
      echo "DKMS Gasket module: $dkms_gasket"
  else
      echo "Gasket DKMS module not found."
      status_failed=true
  fi

  # Apex module version if loaded
  if command -v modinfo >/dev/null && lsmod | grep -q '^apex '; then
      apex_version=$(modinfo apex | grep '^version:' | awk '{print $2}' || true)
      if [ -n "$apex_version" ]; then
          echo "Apex module version: $apex_version"
      fi
  else
      echo "Apex module not loaded."
      status_failed=true
  fi

  # libedgetpu version
  lib_version=$(dpkg -l | grep libedgetpu1-std | awk '{print $3}' || true)
  if [ -n "$lib_version" ]; then
      echo "libedgetpu1-std version: $lib_version"
  else
      echo "libedgetpu1-std not installed."
      status_failed=true
  fi
  
  echo -e "\nNon-root access:"

  # Udev rule and group for non-root access
  if [ -f "$UDEV_RULE" ]; then
      echo "Udev rule for non-root access: present."
  else
      echo "Udev rule for non-root access: not present."
  fi

  if getent group apex >/dev/null; then
      echo "Apex group for non-root access: present."
      members=$(getent group apex | cut -d: -f4)
      echo "Members: $members"
  else
      echo "Apex group for non-root access: not present."
  fi

  if [ "$status_failed" = true ]; then
      echo -e "Driver installation validation failed. \n"
      display_usage
  fi
}

install() {
  if [ "$EUID" -ne 0 ]; then
    echo "Please run as root (sudo $0 install)"
    exit 1
  fi

  # Check if gasket-dkms is installed and /dev/apex_0 exists
  if dpkg -l | grep -q gasket-dkms && [ -e /dev/apex_0 ]; then
    echo "Driver already installed and functional. Verify with: ls /dev/apex_0"
    echo "To reinstall: sudo $0 reinstall"
    echo "To rebuild for current kernel: sudo $0 rebuild"
    exit 0
  fi

  # Install build prerequisites
  echo "Installing prerequisites..."
  apt update || { echo "Error: Failed to run apt update"; exit 1; }
  apt install -y curl gpg dkms build-essential devscripts linux-headers-$(uname -r) || \
    { echo "Error: Failed to install prerequisites"; exit 1; }

  install_libedgetpu

  # Build and install from GitHub
  install_driver

  echo "Installation complete."
  prompt_reboot
}

install_libedgetpu() {
  echo "Adding Coral Edge TPU repository..."

  # Add Coral repository for libedgetpu1-std
  mkdir -p /etc/apt/keyrings || { echo "Error: Failed to create /etc/apt/keyrings"; exit 1; }
  
  curl -fsSL https://packages.cloud.google.com/apt/doc/apt-key.gpg | gpg --dearmor -o "$KEYRING" || \
    { echo "Error: Failed to download/process Coral GPG key"; exit 1; }
  echo "deb [signed-by=$KEYRING] https://packages.cloud.google.com/apt coral-edgetpu-stable main" | tee "$SOURCES" || \
    { echo "Error: Failed to add Coral repository"; exit 1; }
  apt update || { echo "Error: Failed to update apt after adding Coral repository"; exit 1; } 

  apt install -y libedgetpu1-std || { echo "Error: Failed to install libedgetpu1-std"; exit 1; }
}

install_driver() {
  echo "Installing driver from source..."

  # Clean up build directory
  if [ -d "/tmp/coral-build" ]; then
    rm -rf "/tmp/coral-build" || { echo "Error: Failed to remove /tmp/coral-build"; exit 1; }
  fi

  mkdir -p "/tmp/coral-build" || { echo "Error: Failed to create /tmp/coral-build"; exit 1; }
  git clone "https://github.com/google/gasket-driver.git" "/tmp/coral-build/gasket-driver" || \
    { echo "Error: Failed to clone gasket-driver"; exit 1; }
  
  cd "/tmp/coral-build/gasket-driver" || { echo "Error: Failed to change to gasket-driver directory"; exit 1; }
  
  # Pull request 'Update for Kernel 6.13+' remove if no longer needed
  git fetch origin pull/50/head:pr-50 || { echo "Error: Failed to fetch PR 50"; exit 1; }
  git checkout pr-50 || { echo "Error: Failed to checkout PR 50 branch"; exit 1; }
  # end PR 50
  
  debuild -us -uc -tc -b || { echo "Error: Failed to build gasket-dkms"; exit 1; }
  deb_file=$(ls ../gasket-dkms_*_all.deb | head -n 1)
  if [ -z "$deb_file" ]; then
    echo "Error: No gasket-dkms .deb file found"
    exit 1
  fi
  dpkg -i "$deb_file" || { echo "Error: Failed to install gasket-dkms"; exit 1; }
  
  rm -rf "/tmp/coral-build"
  
}

uninstall() {
  if [ "$EUID" -ne 0 ]; then
    echo "Please run as root (sudo $0 uninstall)"
    exit 1
  fi

  # Remove packages
  apt remove --purge -y gasket-dkms libedgetpu1-std || true

  # Clean up files
  rm -f "$SOURCES" "$KEYRING" "$UDEV_RULE"
  rm -rf /usr/src/gasket-*  

  # Remove group
  groupdel apex 2>/dev/null || true

  # Update initramfs
  update-initramfs -u || { echo "Error: Failed to update initramfs"; exit 1; }

  echo "Uninstallation complete"
  prompt_reboot
}

reinstall() {
  if [ "$EUID" -ne 0 ]; then
    echo "Please run as root (sudo $0 reinstall)"
    exit 1
  fi

  uninstall
  install_libedgetpu
  echo "Reinstalling driver..."
  install_driver
  
  echo "Driver reinstalled. Verify with: ls /dev/apex_0"
  prompt_reboot
}

rebuild() {
  if [ "$EUID" -ne 0 ]; then
    echo "Please run as root (sudo $0 rebuild)"
    exit 1
  fi

  # Ensure kernel headers
  apt install -y linux-headers-$(uname -r) || {
    echo "Error: Failed to install linux-headers-$(uname -r)"
    exit 1
  }

  # Find gasket-dkms version
  gasket_dir=$(ls -d /usr/src/gasket-* 2>/dev/null | head -n 1)
  if [ -z "$gasket_dir" ]; then
    echo "Error: No gasket-dkms source found in /usr/src"
    exit 1
  fi
  gasket_version=$(basename "$gasket_dir" | sed 's/gasket-//')

  # Force rebuild DKMS module
  dkms install --force gasket/"$gasket_version" -k $(uname -r) || {
    echo "Error: Failed to force-rebuild gasket-dkms"
    exit 1
  }

  # Check for processes using apex
  if lsof /dev/apex_0 >/dev/null 2>&1; then
    echo "Warning: Module apex is in use. Processes using /dev/apex_0:"
    lsof /dev/apex_0
    echo "Please terminate these processes and retry, or reboot to reload modules."
    prompt_reboot
    exit 1
  fi

  # Reload module
  if ! modprobe -r apex gasket 2>&1; then
    echo "Warning: Failed to unload apex/gasket modules"
    prompt_reboot
    exit 1
  fi
  modprobe apex || {
    echo "Error: Failed to load apex module"
    exit 1
  }

  echo "Driver rebuilt."
}

setup_non_root_access() {
  local username="$1"

  # If no username provided, use SUDO_USER or prompt
  if [ -z "$username" ]; then
    if [ -n "$SUDO_USER" ]; then
      username="$SUDO_USER"
    else
      echo -n "Enter username: "
      read -r username
    fi
  fi

  # Validate username
  if ! id "$username" >/dev/null 2>&1; then
    echo "Error: User $username does not exist"
    return 1
  fi

  # Create apex group and add user
  groupadd -f apex || { echo "Error: Failed to create apex group"; return 1; }
  usermod -aG apex "$username" || { echo "Error: Failed to add $username to apex group"; return 1; }

  # Set up udev rule
  echo 'SUBSYSTEM=="apex", MODE="0660", GROUP="apex"' > "$UDEV_RULE" || \
    { echo "Error: Failed to create udev rule"; return 1; }
  udevadm control --reload-rules && udevadm trigger || \
    { echo "Error: Failed to reload udev rules"; return 1; }

  echo "Non-root access set for $username"
}

case "$1" in
  --install)
    install
    ;;
  --uninstall)
    uninstall
    ;;
  --reinstall)
    reinstall
    ;;
  --rebuild)
    rebuild
    ;;
  --setup-non-root)
    if [ "$EUID" -ne 0 ]; then
      echo "Please run as root (sudo $0 setup-non-root [username])"
      exit 1
    fi
    setup_non_root_access "${2:-$SUDO_USER}"
    ;;
  --status)
    status
    ;;    
  *)
    display_usage
    ;;
esac
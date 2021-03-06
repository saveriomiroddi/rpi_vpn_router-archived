#!/bin/bash

set -o errexit

# GENERAL NOTES ################################################################

# Temporary files/subdirs are deleted immediately after usage, with an
# exception: if DONT_DELETE_ARCHIVES=1, then the archives are not deleted.

# VARIABLES/CONSTANTS ##########################################################

c_project_archive_base_address=https://github.com/saveriomiroddi/rpi_vpn_router/archive
c_os_archive_address=http://vx2-downloads.raspberrypi.org/raspbian_lite/images/raspbian_lite-2017-09-08/2017-09-07-raspbian-stretch-lite.zip
c_data_dir_mountpoint=/mnt
c_data_partition_default_size=1806  # could be dynamically retrieved, but would
                                    # disrupt the sequence

# There are no clean solutions in bash fo capturing multiple return values,
# so for this case, globals are ok, esprcially considering that processing
# is performed in a strictly linear fashion (no reassignments, etc.).
v_temp_path=       # use this only inside download_and_unpack_archives()...
v_project_path=    # ... and this for all the rest
v_sdcard_device=
v_data_partition_size=
v_rpi_static_ip_on_modem_net=
v_rpi_hostname=
v_disable_on_board_wireless=
v_pia_user=
v_pia_password=
v_pia_server=
v_pia_dns_server_1=
v_pia_dns_server_2=
v_os_image_filename=

if [[ "$REPO_BRANCH" == "" ]]; then
  v_repo_branch=master
else
  v_repo_branch="$REPO_BRANCH"
fi

# HELPERS ######################################################################

function find_usb_storage_devices {
  for device in /sys/block/*; do
    local usb_storages_info
    usb_storages_info=$(udevadm info --query=property --path="$device")

    if echo "$usb_storages_info" | grep -q ^ID_BUS=usb; then
      devname=$(echo "$usb_storages_info" | grep ^DEVNAME= | perl -pe 's/DEVNAME=//')
      model=$(echo "$usb_storages_info" | grep ^ID_MODEL= | perl -pe 's/ID_MODEL=//')
      v_usb_storage_devices[$devname]=$model
    fi
  done
}

# MAIN FUNCTIONS ###############################################################

function check_sudo {
  if [[ "$EUID" != 0 ]]; then
    whiptail --msgbox "Please re-run this script as root!" 30 100
    exit
  fi
}

function print_intro {
  whiptail --msgbox "Hello! This script will prepare an SDCard for using un a RPi3 as VPN router.

Please note that device events (eg. automount) are disabled during the script execution." 30 100
}

# udev has lots of potentional for causing a mess while operating with partitions,
# images, etc., so we disable the events processing.
function disable_udev_processing {
  udevadm control --stop-exec-queue
}

function restore_udev_processing {
  udevadm control --start-exec-queue
}

function ask_temp_path {
  v_temp_path=$(whiptail --inputbox 'Enter the temporary directory (requires about 2 GiB of free space).

Leave blank for using the default (`/tmp`).' 30 100 3>&1 1>&2 2>&3)

  if [[ "$v_temp_path" == "" ]]; then
    v_temp_path="/tmp"
  fi

  v_project_path="$v_temp_path/rpi_vpn_router-$v_repo_branch"
}

function ask_sdcard_device {
  while [[ "$v_sdcard_device" == "" ]]; do
    declare -A v_usb_storage_devices

    find_usb_storage_devices

    if [[ ${#v_usb_storage_devices[@]} -gt 0 ]]; then
      local entries_option=""
      local entries_count=0
      local message=$'Choose SDCard device. THE CARD/DEVICE WILL BE COMPLETELY ERASED.\n\nAvailable (USB) devices:\n\n'

      for dev in "${!v_usb_storage_devices[@]}"; do
        entries_option+=" $dev "
        entries_option+=$(printf "%q" "${v_usb_storage_devices[$dev]}")
        entries_option+=" OFF"

        entries_count=$((entries_count + 1))
      done

      v_sdcard_device=$(whiptail --radiolist "$message" 30 100 $entries_count $entries_option 3>&1 1>&2 2>&3);
    else
      whiptail --msgbox "No (USB) devices found. Plug one and press Enter." 30 100
    fi

    unset v_usb_storage_devices
  done
}

function ask_data_partition_size {
  while true; do
    v_data_partition_size=$(whiptail --inputbox "Enter the size of the data partition (in million bytes)

The size must be numbers only, and greater than $c_data_partition_default_size.

Leave blank for leaving the default size ($c_data_partition_default_size)." 30 100 3>&1 1>&2 2>&3)

    if [[ "$v_data_partition_size" == "" ]]; then
      break
    elif [[ $v_data_partition_size =~ ^[0-9]+$ && "$v_data_partition_size" > "$c_data_partition_default_size" ]]; then
      break
    fi
  done
}

function ask_rpi_static_ip_on_modem_net {
  while true; do
    v_rpi_static_ip_on_modem_net=$(whiptail --inputbox $'Enter the RPi static IP on the modem network (eth0 on the RPi)

Leave blank for automatic assignment (use DHCP).' 30 100 3>&1 1>&2 2>&3)

    if [[ $v_rpi_static_ip_on_modem_net =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]]; then
      break
    elif [[ "$v_rpi_static_ip_on_modem_net" == "" ]]; then
      break
    fi
  done
}

function ask_rpi_hostname {
  v_rpi_hostname=$(whiptail --inputbox $'Enter the RPi hostname.

Leave blank for using `raspberrypi`' 30 100 3>&1 1>&2 2>&3)
}

function ask_disable_on_board_wireless {
  if (whiptail --yesno $'Disable on board wireless (WiFi/Bluetooth, on RPi3)?


On RPi 3, it\'s advised to choose `Yes`, since the traffic will go through eth0; choosing `No` will yield a working VPN Router nonetheless.

On other models, the choice won\'t have any effect.
' 30 100); then
    v_disable_on_board_wireless=1
  fi
}

function ask_pia_data {
  while [[ "$v_pia_user" == "" ]]; do
    v_pia_user=$(whiptail --inputbox $'Enter the PrivateInternetAccess user' 30 100 3>&1 1>&2 2>&3)
  done

  while [[ "$v_pia_password" == "" ]]; do
    v_pia_password=$(whiptail --inputbox $'Enter the PrivateInternetAccess password' 30 100 3>&1 1>&2 2>&3)
  done

  while [[ "$v_pia_server" == "" ]]; do
    v_pia_server=$(whiptail --inputbox 'Enter the PrivateInternetAccess server (eg. germany.privateinternetaccess.com).

You can find the list at https://www.privateinternetaccess.com/pages/network' 30 100 3>&1 1>&2 2>&3)
  done

  while true; do
    v_pia_dns_server_1=$(whiptail --inputbox 'Enter the PrivateInternetAccess DNS server 1 IP.

Leave blank for using the default PIA DNS Server #1 (209.222.18.222)' 30 100 3>&1 1>&2 2>&3)

    if [[ $v_pia_dns_server_1 =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]]; then
      break
    elif [[ "$v_pia_dns_server_1" == "" ]]; then
      v_pia_dns_server_1="209.222.18.222";
      break
    fi
  done

  while true; do
    v_pia_dns_server_2=$(whiptail --inputbox 'Enter the PrivateInternetAccess DNS server 2 IP.

Leave blank for using the default PIA DNS Server #2 (209.222.18.218)' 30 100 3>&1 1>&2 2>&3)

    if [[ $v_pia_dns_server_2 =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]]; then
      break
    elif [[ "$v_pia_dns_server_2" == "" ]]; then
      v_pia_dns_server_2="209.222.18.218"
      break
    fi
  done
}

function download_and_unpack_archives {
  local os_archive_filename="$v_temp_path/${c_os_archive_address##*/}"
  v_os_image_filename="${os_archive_filename%.zip}.img"

  wget -cO "$os_archive_filename" "$c_os_archive_address" 2>&1 | \
   stdbuf -o0 awk '/[.] +[0-9][0-9]?[0-9]?%/ { print substr($0,63,3) }' | \
   whiptail --gauge "Downloading O/S image..." 30 100 0

  unzip -o "$os_archive_filename" -d "$v_temp_path"

  [[ "$DONT_DELETE_ARCHIVES" != 1 ]] && rm "$os_archive_filename"

  local project_archive_address="$c_project_archive_base_address/$v_repo_branch.zip"
  local project_archive_filename="$v_project_path.zip"

  wget -cO "$project_archive_filename" "$project_archive_address" 2>&1 | \
   stdbuf -o0 awk '/[.] +[0-9][0-9]?[0-9]?%/ { print substr($0,63,3) }' | \
   whiptail --gauge "Downloading project archive..." 30 100 0

  rm -rf "$v_project_path"

  unzip "$project_archive_filename" -d "$v_temp_path"

  [[ "$DONT_DELETE_ARCHIVES" != 1 ]] && rm "$project_archive_filename"
}

function resize_image_data_partition {
  if [[ "$v_data_partition_size" != "" ]]; then
    # Round to the next multiple of 512, if not a multiple already.
    local size_increase_sectors
    size_increase_sectors=$(( (1000000 * (v_data_partition_size - c_data_partition_default_size) + 511) / 512 ))

    (dd status=progress if=/dev/zero bs=512 count=$size_increase_sectors >> "$v_os_image_filename") 2>&1 | \
      stdbuf -o0 awk -v RS='\r' "/copied/ { printf(\"%0.f\\n\", \$1 / ($size_increase_sectors * 512) * 100) }" | \
      whiptail --gauge "Appending empty space to the image data partition..." 30 100 0

    local loop_device
    local start_of_second_partition
    loop_device=$(losetup -f -P --show "$v_os_image_filename")
    start_of_second_partition=$(parted -m "$loop_device" print | awk -F: '/^2:/ {print $2}')

    # Using 100% will avoid the annoying alignment problem.
    parted "$loop_device" 'rm 2' "mkpart primary $start_of_second_partition 100%"

    e2fsck -f "${loop_device}p2"
    resize2fs "${loop_device}p2"

    losetup -d "$loop_device"
  fi
}

function process_project_files {
  # The symlink is not included, but it doesn't have (meaningful) permissions.
  find "$v_project_path/configfiles" -type d -exec chmod 755 {} \;
  find "$v_project_path/configfiles" -type f -name '*.sh' -exec chmod 755 {} \;

  find "$v_project_path/configfiles" \
       -type f \
       -not -name '*.sh' \
       -not -path "$v_project_path/configfiles/etc/cron.d/*" \
       -exec chmod 644 {} \;

  # Files used by services that raise warnings if they don't have specific permissions.
  find "$v_project_path/configfiles/etc/cron.d" -type f -exec chmod 600 {} \;
  chmod 600 "$v_project_path/configfiles/etc/openvpn/pia/auth.conf"
}

function unmount_sdcard_partitions {
  if mount | grep -q "^$v_sdcard_device"; then
    for partition in $(mount | grep "^$v_sdcard_device" | awk '{print $1}'); do
      umount "$partition" 2> /dev/null || true
    done
  fi

  while mount | grep -q "^$v_sdcard_device"; do
    local message=$'There are still some partitions mounted in the sdcard device that couldn\'t be unmounted:\n\n'

    while IFS=$'\n' read -r partition_data; do
      echo "$partition_data"
      local partition_description
      partition_description=$(echo "$partition_data" | awk '{print $1 " " $2 " " $3}')
      message+="$partition_description
"
    done <<< "$(mount | grep "^$v_sdcard_device")"

    message+=$'\nPlease unmount them, then press Enter.'

    whiptail --yesno "$message" 30 100
  done
}

function burn_image {
  local os_image_size
  os_image_size=$(stat -c "%s" "$v_os_image_filename")

  # dd doesn't print newlines, so we need to detect the progress change events
  # using carriage return as separator
  (dd status=progress if="$v_os_image_filename" of="$v_sdcard_device") 2>&1 | \
    stdbuf -o0 awk -v RS='\r' "/copied/ { printf(\"%0.f\\n\", \$1 / $os_image_size * 100) }" | \
    whiptail --gauge "Burning the image on the SD card..." 30 100 0

  rm "$v_os_image_filename"
}

function mount_data_partition {
  # Need to wait a little bit for the OS to recognize the device and the partitions...
  #
  while [[ ! -e "${v_sdcard_device}2" ]]; do
    sleep 0.5
  done

  # Wait a little bit! Otherwise, trying to mount will make a mess - it may fail
  # and cause the devices disconnection (!).
  sleep 1

  mount "${v_sdcard_device}2" "$c_data_dir_mountpoint"
}

function copy_system_files {
  tar xvf "$v_project_path/processed_image_diff/processed_image.tar.xz" -C "$c_data_dir_mountpoint"

  # Delete files that can't be deleted by the tar operation.
  rm "$c_data_dir_mountpoint/etc/init/ssh.override"
  rm "$c_data_dir_mountpoint/etc/rc2.d/K01ssh"
  rm "$c_data_dir_mountpoint/etc/rc3.d/K01ssh"
  rm "$c_data_dir_mountpoint/etc/rc4.d/K01ssh"
  rm "$c_data_dir_mountpoint/etc/rc5.d/K01ssh"

  rsync --recursive --links --perms --exclude .gitkeep "$v_project_path/configfiles/" "$c_data_dir_mountpoint"

  rm -rf "$v_project_path"
}

function update_configuration_files {
  # PIA configuration ######################################
  perl -i -pe "s/__PIA_USER__/$v_pia_user/" "$c_data_dir_mountpoint/etc/openvpn/pia/auth.conf"
  perl -i -pe "s/__PIA_PASSWORD__/$v_pia_password/" "$c_data_dir_mountpoint/etc/openvpn/pia/auth.conf"
  perl -i -pe "s/__PIA_SERVER_ADDRESS__/$v_pia_server/" "$c_data_dir_mountpoint/etc/openvpn/pia/default.ovpn"

  # Hostname (if provided) #################################
  if [[ "$v_rpi_hostname" != "" ]]; then
    perl -i -pe "s/raspberrypi/$v_rpi_hostname/" "$c_data_dir_mountpoint/etc/hosts"
    echo "$v_rpi_hostname" > "$c_data_dir_mountpoint/etc/hostname"
  fi

  # On-board Wireless blacklisting #########################

  if [[ "$v_disable_on_board_wireless" != 1 ]]; then
    rm "$c_data_dir_mountpoint/etc/modprobe.d/blacklist-rpi3-wireless.conf"
  fi

  # Networking #############################################

  # If DHCP is used on the modem/router side, nothing needs
  # to be added.
  if [[ "$v_rpi_static_ip_on_modem_net" != "" ]]; then
    local modem_ip
    modem_ip=$(perl -pe 's/\.\d+$/.1/' <<< "$v_rpi_static_ip_on_modem_net")

    # Tabs are at risk to be autoconverted to spaces while editing,
    # so it's better not to use `<<-`.
    cat >> "$c_data_dir_mountpoint/etc/dhcpcd.conf" <<EOS
interface eth0
static ip_address=$v_rpi_static_ip_on_modem_net/24
static routers=$modem_ip
static domain_name_servers=$v_pia_dns_server_1 $v_pia_dns_server_2

EOS
  fi

  cat >> "$c_data_dir_mountpoint/etc/dhcpcd.conf" <<EOS
interface eth1
static ip_address=192.168.166.1/24

EOS

  # DHCP Server ############################################

  perl -i -pe "s/__PIA_DNS_SERVER_1__/$v_pia_dns_server_1/" "$c_data_dir_mountpoint/etc/dnsmasq.d/eth1-access-point-net.conf"
  perl -i -pe "s/__PIA_DNS_SERVER_2__/$v_pia_dns_server_2/" "$c_data_dir_mountpoint/etc/dnsmasq.d/eth1-access-point-net.conf"
}

function eject_sdcard {
  eject "$v_sdcard_device"
}

function print_post_configuration_intructions {
  whiptail --msgbox "The SD card is ready.

Now:

- connect the ISP modem/router to the RPi internal ethernet port;
- insert the SD card and plug the ethernet dongle to the RPi, then boot it;
- connect the Wifi access point to the Ethernet dongle

... now enjoy your RPi3 VPN router!
" 30 100
}

# MAIN #########################################################################

check_sudo

print_intro

disable_udev_processing
trap restore_udev_processing EXIT

ask_temp_path
ask_sdcard_device
ask_data_partition_size
ask_rpi_static_ip_on_modem_net
ask_rpi_hostname
ask_disable_on_board_wireless
ask_pia_data

download_and_unpack_archives
resize_image_data_partition
process_project_files
unmount_sdcard_partitions
burn_image

mount_data_partition
copy_system_files
update_configuration_files
eject_sdcard

print_post_configuration_intructions

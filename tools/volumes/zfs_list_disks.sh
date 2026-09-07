#!/usr/bin/env bash
# zfs_list_disks.sh
#
# Lists all disks used by ZFS pools.
#
# Usage: ./zfs_list_disks.sh
#
# Output:
#   List of disks used by ZFS pools, with pool name and device path
#
# Example output:
#   [
#     {"pool":"tank","device":"/dev/disk/by-id/scsi-0DO_Volume_volume-nyc1-01"},
#     {"pool":"data","device":"/dev/disk/by-id/scsi-0DO_Volume_volume-nyc1-02"}
#   ]
#
# Requires:
#   - zfsutils-linux
#   - jq

set -e

# Check if zfs is installed
if ! command -v zpool &> /dev/null; then
  echo -e "\033[0;34mInstalling ZFS utilities...\033[0m"
  apt-get update -qq && apt-get install -y zfsutils-linux -qq
fi

# Check if jq is installed
if ! command -v jq &> /dev/null; then
  echo -e "\033[0;34mInstalling jq...\033[0m"
  apt-get update -qq && apt-get install -y jq -qq
fi

# Get all ZFS pools
pools=$(zpool list -H -o name 2>/dev/null || echo "")

if [ -z "$pools" ]; then
  # No pools found, return empty array
  echo "[]"
  exit 0
fi

# Initialize results array
results=()

for pool in $pools; do
  # Get devices used by this pool
  # The awk pattern matches device names that are not part of mirror/raidz descriptions
  devices=$(zpool status "$pool" | awk '/^\t  (scsi|sd|vd|xvd|nvme)/ {print $1}')
  
  for device in $devices; do
    # Check if the device is a full path
    if [[ "$device" != /* ]]; then
      # Try to find the full path in /dev/disk/by-id
      by_id_path=$(find /dev/disk/by-id -type l -not -name "*-part*" 2>/dev/null | 
                 xargs -I{} bash -c 'if [[ "$(readlink -f {})" == "/dev/'$device'" ]]; then echo "{}"; fi' | 
                 head -1)
      
      if [ -n "$by_id_path" ]; then
        device="$by_id_path"
      else
        device="/dev/$device"
      fi
    fi
    
    # Add to results
    results+=("{\"pool\":\"$pool\",\"device\":\"$device\"}")
  done
done

# Join results and output as JSON array
echo "[$(IFS=,; echo "${results[*]}")]"

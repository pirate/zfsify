#!/usr/bin/env bash
# find_new_disks.sh
#
# Finds new unformatted disks that are not part of any ZFS pool
#
# Usage: ./find_new_disks.sh [--all|--largest]
#
# Arguments:
#   --all     : Returns all available unformatted disks (default)
#   --largest : Returns only the largest unformatted disk
#
# Output:
#   List of disk paths (one per line)
#   If --largest is specified, only returns the largest disk
#
# Example output (with --all):
#   /dev/disk/by-id/scsi-0DO_Volume_volume-nyc1-01
#   /dev/disk/by-id/scsi-0DO_Volume_volume-nyc1-02
#
# Example output (with --largest):
#   /dev/disk/by-id/scsi-0DO_Volume_volume-nyc1-01
#
# Requires:
#   - zfsutils-linux

set -e

# Parse arguments
RETURN_MODE="all"
if [ "$1" = "--largest" ]; then
  RETURN_MODE="largest"
fi

# Check if zfs is installed
if ! command -v zpool &> /dev/null; then
  echo -e "\033[0;34mInstalling ZFS utilities...\033[0m"
  apt-get update -qq && apt-get install -y zfsutils-linux -qq
fi

# Function to scan for new unformatted drives and pick suitable ones
find_new_drives() {
  echo -e "\033[0;34mScanning for SCSI drives...\033[0m" >&2

  # Get all SCSI drives
  all_drives=$(ls /dev/disk/by-id/scsi-* 2>/dev/null | grep -v "part[0-9]" || echo "")
  
  echo -e "\033[0;36mFound $(echo "$all_drives" | wc -l) SCSI drives to check...\033[0m" >&2

  # If no SCSI drives found, try to use regular drives
  if [[ -z "$all_drives" ]]; then
    echo -e "\033[0;33mNo SCSI drives found, falling back to regular block devices\033[0m" >&2
    all_drives=$(lsblk -dpno NAME | grep -v 'loop\|sr0\|zd\|[0-9]$')
  fi
  
  echo -e "\033[0;36mTotal $(echo "$all_drives" | wc -l) drives to check...\033[0m" >&2

  # Find drives with no partitions
  local candidate_drives=()
  local drive_sizes=()
  
  for drive in $all_drives; do
    # Skip empty lines
    if [[ -z "$drive" ]]; then
      continue
    fi
    
    # Get real path of the drive
    local real_drive=$(readlink -f "$drive")
    local real_name=$(basename "$real_drive")
    local name=$(basename "$drive")

    # Skip if this is a partition (has "-part" in the name or ends with a number)
    if [[ "$drive" =~ -part[0-9]+ || "$drive" =~ [0-9]$ ]]; then
      echo -e "\033[0;36mSkipping drive: $drive (is a partition)\033[0m" >&2
      continue
    fi
    
    # Skip if real path is a partition (ends with a number)
    if [[ "$(basename "$real_drive")" =~ [0-9]$ ]]; then
      echo -e "\033[0;36mSkipping drive: $drive (is a partition)\033[0m" >&2
      continue
    fi
    
    # Skip if drive is used by ZFS
    if zpool status 2>/dev/null | grep -qE "($real_name)|($name)"; then
      echo -e "\033[0;36mSkipping drive: $drive (is a ZFS vdev)\033[0m" >&2
      continue
    fi
    
    # Skip if drive is part of any ZFS pool (more thorough check)
    if zpool list -v 2>/dev/null | grep -qE "($real_name)|($name)"; then
      echo -e "\033[0;36mSkipping drive: $drive (is part of ZFS pool)\033[0m" >&2
      continue
    fi
    
    # Skip if drive has partitions
    if [[ $(lsblk -no NAME "$real_drive" | wc -l) -gt 1 ]] || [[ $(lsblk -no NAME "$drive" | wc -l) -gt 1 ]]; then
      echo -e "\033[0;36mSkipping drive: $drive (has partitions)\033[0m" >&2
      continue
    fi
    
    # Check for existing partition table or filesystem signatures
    if sfdisk -d "$real_drive" 2>/dev/null | grep -q "^/"; then
      echo -e "\033[0;36mSkipping drive: $drive (has partition table)\033[0m" >&2
      continue
    fi
    
    # Check if drive has any filesystem signature
    if wipefs -n "$real_drive" 2>/dev/null | grep -q -E 'filesystem|partition-table'; then
      echo -e "\033[0;36mSkipping drive: $drive (has filesystem signature)\033[0m" >&2
      continue
    fi
    
    # Double check that this is a whole disk and not a partition
    if lsblk -dno TYPE "$real_drive" | grep -q "part"; then
      echo -e "\033[0;36mSkipping drive: $drive (has partition)\033[0m" >&2
      continue
    fi
    
    # Get drive size in bytes
    local size=$(lsblk -bno SIZE "$real_drive" 2>/dev/null | head -1)
    
    # Add to candidate drives
    candidate_drives+=("$drive")
    drive_sizes+=("$size")
    
    echo -e "\033[0;32mFound candidate drive: $drive ($(numfmt --to=iec-i --suffix=B --format="%.2f" $size))\033[0m" >&2
  done
  
  # If no candidate drives found
  if [[ ${#candidate_drives[@]} -eq 0 ]]; then
    echo -e "\033[0;33mNo unformatted drives found\033[0m" >&2
    return 1
  fi
  
  # If we need to return all drives
  if [[ "$RETURN_MODE" == "all" ]]; then
    for drive in "${candidate_drives[@]}"; do
      echo "$drive"
    done
    return 0
  fi
  
  # Otherwise, find the largest drive
  local max_size=0
  local max_idx=0
  
  for i in "${!drive_sizes[@]}"; do
    if [[ ${drive_sizes[$i]} -gt $max_size ]]; then
      max_size=${drive_sizes[$i]}
      max_idx=$i
    fi
  done
  
  # Return the largest drive
  echo "${candidate_drives[$max_idx]}"
}

# Execute the function
find_new_drives

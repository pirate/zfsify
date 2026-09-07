#!/usr/bin/env bash
# summarize_storage.sh
#
# Summarizes all ZFS pools and their corresponding DigitalOcean volumes
#
# Usage: ./summarize_storage.sh
#
# Output:
#   Human-readable summary of ZFS pools and DigitalOcean volumes
#
# Requires:
#   - zfsutils-linux
#   - jq
#   - DO_API_TOKEN environment variable (for volume information)

set -e

# Colors
GREEN='\033[0;32m'
BLUE='\033[0;34m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# Check if zfs is installed
if ! command -v zpool &> /dev/null; then
  echo -e "${BLUE}Installing ZFS utilities...${NC}"
  apt-get update -qq && apt-get install -y zfsutils-linux -qq
fi

# Check if jq is installed
if ! command -v jq &> /dev/null; then
  echo -e "${BLUE}Installing jq...${NC}"
  apt-get update -qq && apt-get install -y jq -qq
fi

# Function to format size
format_size() {
  local size=$1
  if (( $(echo "$size > 1073741824" | bc -l) )); then
    echo $(printf "%.2f TB" $(echo "$size/1073741824" | bc -l))
  elif (( $(echo "$size > 1048576" | bc -l) )); then
    echo $(printf "%.2f GB" $(echo "$size/1048576" | bc -l))
  elif (( $(echo "$size > 1024" | bc -l) )); then
    echo $(printf "%.2f MB" $(echo "$size/1024" | bc -l))
  else
    echo $(printf "%d KB" $size)
  fi
}

# Print header
echo -e "\n${BOLD}${BLUE}========== Storage Summary ==========${NC}"

# Get region from metadata service
REGION=$(curl -s http://169.254.169.254/metadata/v1/region 2>/dev/null || echo "")

# Get all ZFS pools
pools=$(zpool list -H -o name 2>/dev/null || echo "")

if [ -z "$pools" ]; then
  echo -e "${YELLOW}No ZFS pools found${NC}"
else
  echo -e "\n${BOLD}${CYAN}ZFS Pools:${NC}"
  
  # Print header row
  printf "${BOLD}%-20s %-15s %-15s %-15s %-20s${NC}\n" "Pool Name" "Size" "Used" "Available" "Health"
  
  for pool in $pools; do
    # Get pool details
    pool_info=$(zpool list -H -o name,size,alloc,free,health "$pool")
    name=$(echo "$pool_info" | awk '{print $1}')
    size=$(echo "$pool_info" | awk '{print $2}')
    used=$(echo "$pool_info" | awk '{print $3}')
    avail=$(echo "$pool_info" | awk '{print $4}')
    health=$(echo "$pool_info" | awk '{print $5}')
    
    # Colorize health status
    if [ "$health" == "ONLINE" ]; then
      health_color="${GREEN}$health${NC}"
    else
      health_color="${RED}$health${NC}"
    fi
    
    printf "%-20s %-15s %-15s %-15s %-20s\n" "$name" "$size" "$used" "$avail" "$health_color"
  done
  
  # Show datasets summary
  echo -e "\n${BOLD}${CYAN}ZFS Datasets:${NC}"
  zfs list -o name,used,avail,refer,mountpoint | grep -v "^NAME" | sort
fi

# Get information about DigitalOcean volumes if DO_API_TOKEN is set
if [ -n "$DO_API_TOKEN" ] && [ -n "$REGION" ]; then
  echo -e "\n${BOLD}${CYAN}DigitalOcean Volumes:${NC}"
  
  response=$(curl -s -X GET \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer $DO_API_TOKEN" \
    "https://api.digitalocean.com/v2/volumes?region=$REGION" 2>/dev/null || echo '{"volumes":[]}')
  
  volumes=$(echo "$response" | jq -r '.volumes[]? | "\(.name) \(.size_gigabytes) \(.filesystem_type) \(.droplet_ids | join(","))"' 2>/dev/null || echo "")
  
  if [ -z "$volumes" ]; then
    echo -e "${YELLOW}No DigitalOcean volumes found in region $REGION${NC}"
  else
    # Print header row
    printf "${BOLD}%-25s %-15s %-15s %-20s %-25s${NC}\n" "Volume Name" "Size" "Filesystem" "Attached To" "Device Path"
    
    while read -r line; do
      if [ -n "$line" ]; then
        name=$(echo "$line" | awk '{print $1}')
        size="${BOLD}$(echo "$line" | awk '{print $2}')${NC} GB"
        fs_type=$(echo "$line" | awk '{print $3}')
        droplet_ids=$(echo "$line" | awk '{print $4}')
        
        # Try to find the device path
        device_path="/dev/disk/by-id/scsi-0DO_Volume_${name}"
        if [ ! -e "$device_path" ]; then
          device_path="${YELLOW}Not attached${NC}"
        fi
        
        printf "%-25s %-15s %-15s %-20s %-25s\n" "$name" "$size" "$fs_type" "$droplet_ids" "$device_path"
      fi
    done <<< "$volumes"
  fi
fi

# Show mapping between ZFS pools and DigitalOcean volumes
echo -e "\n${BOLD}${CYAN}ZFS Pool to DigitalOcean Volume Mapping:${NC}"

if [ -z "$pools" ]; then
  echo -e "${YELLOW}No ZFS pools found${NC}"
else
  # Print header row
  printf "${BOLD}%-15s %-35s %-35s${NC}\n" "Pool Name" "Device Path" "DO Volume Name"
  
  for pool in $pools; do
    # Get devices used by this pool
    devices=$(zpool status "$pool" | awk '/^\t  (scsi|sd|vd|xvd|nvme)/ {print $1}')
    
    for device in $devices; do
      # Ensure we have the full path
      if [[ "$device" != /* ]]; then
        device="/dev/$device"
      fi
      
      # Try to find a matching DigitalOcean volume
      volume_name="Unknown"
      if [[ "$device" == *"scsi-0DO_Volume_"* ]]; then
        volume_name=$(basename "$device" | sed 's/scsi-0DO_Volume_//')
      fi
      
      printf "%-15s %-35s %-35s\n" "$pool" "$device" "$volume_name"
    done
  done
fi

echo -e "\n${BOLD}${BLUE}=====================================${NC}\n"

#!/usr/bin/env bash
# zfs_add_mirror.sh
#
# Adds a new device as a mirror to an existing device in a ZFS pool
#
# Usage: ./zfs_add_mirror.sh POOL_NAME DEVICE [MIRROR_TARGET]
#
# Arguments:
#   POOL_NAME     : Name of the existing ZFS pool
#   DEVICE        : Path to the device to add as a mirror
#   MIRROR_TARGET : Optional device to mirror with. If not provided, 
#                   the script will try to find the first suitable device in the pool
#
# Output:
#   ZFS pool status after adding the mirror
#
# Example:
#   ./zfs_add_mirror.sh tank /dev/disk/by-id/scsi-0DO_Volume_volume-nyc1-02
#   ./zfs_add_mirror.sh tank /dev/disk/by-id/scsi-0DO_Volume_volume-nyc1-02 /dev/disk/by-id/scsi-0DO_Volume_volume-nyc1-01
#
# Requires:
#   - zfsutils-linux
#   - parted

set -e

# Colors
GREEN='\033[0;32m'
BLUE='\033[0;34m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
NC='\033[0m' # No Color

# Parse arguments
POOL_NAME="$1"
DEVICE="$2"
MIRROR_TARGET="$3"

# Validate arguments
if [ -z "$POOL_NAME" ]; then
  echo -e "${RED}Error: Pool name is required${NC}"
  echo -e "Usage: $0 POOL_NAME DEVICE [MIRROR_TARGET]"
  exit 1
fi

if [ -z "$DEVICE" ]; then
  echo -e "${RED}Error: Device path is required${NC}"
  echo -e "Usage: $0 POOL_NAME DEVICE [MIRROR_TARGET]"
  exit 1
fi

# Check if device exists
if [ ! -e "$DEVICE" ]; then
  echo -e "${RED}Error: Device $DEVICE does not exist${NC}"
  exit 1
fi

# Check if zfs is installed
if ! command -v zpool &> /dev/null; then
  echo -e "${BLUE}Installing ZFS utilities...${NC}"
  apt-get update -qq && apt-get install -y zfsutils-linux -qq
fi

# Check if parted is installed
if ! command -v parted &> /dev/null; then
  echo -e "${BLUE}Installing parted...${NC}"
  apt-get update -qq && apt-get install -y parted -qq
fi

# Check if pool exists
if ! zpool list "$POOL_NAME" &> /dev/null; then
  echo -e "${RED}Error: Pool $POOL_NAME does not exist${NC}"
  exit 1
fi

# Format the drive as GPT
echo -e "${BLUE}Formatting drive as GPT...${NC}"
wipefs -a "$DEVICE" &> /dev/null
parted "$DEVICE" -s mklabel gpt &> /dev/null

# Enable autoexpand on the pool
echo -e "${BLUE}Enabling autoexpand on pool...${NC}"
zpool set autoexpand=on "$POOL_NAME"

# If mirror target is not provided, find the first suitable device in the pool
if [ -z "$MIRROR_TARGET" ]; then
  echo -e "${BLUE}Finding device to mirror...${NC}"
  
  # Get a list of non-mirrored devices in the pool
  pool_status=$(zpool status "$POOL_NAME")
  
  # Try to find a non-mirrored device
  MIRROR_TARGET=$(echo "$pool_status" | awk '/^\t  (scsi|sd|vd|xvd|nvme)/ && !/(mirror|raidz|spare|log|cache)/ {print $1; exit}')
  
  if [ -z "$MIRROR_TARGET" ]; then
    echo -e "${RED}Error: Could not find a suitable device to mirror with in pool $POOL_NAME${NC}"
    echo -e "Please specify a device to mirror with as the third argument"
    exit 1
  fi
  
  # Resolve to full path if needed
  if [[ "$MIRROR_TARGET" != /* ]]; then
    MIRROR_TARGET="/dev/$MIRROR_TARGET"
  fi
  
  echo -e "${BLUE}Automatically selected device to mirror: $MIRROR_TARGET${NC}"
else
  # Check if mirror target exists
  if [ ! -e "$MIRROR_TARGET" ]; then
    echo -e "${RED}Error: Mirror target $MIRROR_TARGET does not exist${NC}"
    exit 1
  fi
  
  # Check if mirror target is in the pool
  if ! zpool status "$POOL_NAME" | grep -q "$(basename "$MIRROR_TARGET")"; then
    echo -e "${RED}Error: Mirror target $MIRROR_TARGET is not in pool $POOL_NAME${NC}"
    exit 1
  fi
fi

# Add the device as a mirror
echo -e "${BLUE}Adding device $DEVICE as a mirror to $MIRROR_TARGET in pool $POOL_NAME...${NC}"
if zpool attach "$POOL_NAME" "$MIRROR_TARGET" "$DEVICE"; then
  # Expand the pool
  echo -e "${BLUE}Expanding pool...${NC}"
  zpool online -e "$POOL_NAME" "$DEVICE"
  
  echo -e "${GREEN}Device $DEVICE added as a mirror to $MIRROR_TARGET in pool $POOL_NAME successfully${NC}"
  zpool status "$POOL_NAME"
  
  # Check if resilver has started
  if zpool status "$POOL_NAME" | grep -q "resilver in progress"; then
    echo -e "${YELLOW}Resilver is in progress. You can check the status with 'zpool status $POOL_NAME'${NC}"
  fi
  
  exit 0
else
  echo -e "${RED}Failed to add device $DEVICE as a mirror to $MIRROR_TARGET in pool $POOL_NAME${NC}"
  exit 1
fi

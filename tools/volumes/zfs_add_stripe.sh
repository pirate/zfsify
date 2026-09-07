#!/usr/bin/env bash
# zfs_add_stripe.sh
#
# Adds a new device as a stripe vdev to an existing ZFS pool
#
# Usage: ./zfs_add_stripe.sh POOL_NAME DEVICE
#
# Arguments:
#   POOL_NAME : Name of the existing ZFS pool
#   DEVICE    : Path to the device to add as a stripe
#
# Output:
#   ZFS pool status after adding the device
#
# Example:
#   ./zfs_add_stripe.sh tank /dev/disk/by-id/scsi-0DO_Volume_volume-nyc1-02
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

# Validate arguments
if [ -z "$POOL_NAME" ]; then
  echo -e "${RED}Error: Pool name is required${NC}"
  echo -e "Usage: $0 POOL_NAME DEVICE"
  exit 1
fi

if [ -z "$DEVICE" ]; then
  echo -e "${RED}Error: Device path is required${NC}"
  echo -e "Usage: $0 POOL_NAME DEVICE"
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

# Add the device as a stripe to the pool
echo -e "${BLUE}Adding device $DEVICE as a stripe to pool $POOL_NAME...${NC}"
if zpool add "$POOL_NAME" "$DEVICE"; then
  # Expand the pool
  echo -e "${BLUE}Expanding pool...${NC}"
  zpool online -e "$POOL_NAME" "$DEVICE"
  
  echo -e "${GREEN}Device $DEVICE added as a stripe to pool $POOL_NAME successfully${NC}"
  zpool status "$POOL_NAME"
  exit 0
else
  echo -e "${RED}Failed to add device $DEVICE to pool $POOL_NAME${NC}"
  exit 1
fi

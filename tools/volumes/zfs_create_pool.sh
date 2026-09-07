#!/usr/bin/env bash
# zfs_create_pool.sh
#
# Creates a new ZFS pool using the specified disk
#
# Usage: ./zfs_create_pool.sh POOL_NAME DEVICE
#
# Arguments:
#   POOL_NAME : Name for the new ZFS pool
#   DEVICE    : Path to the device to use for the ZFS pool
#
# Output:
#   ZFS pool creation status
#
# Example:
#   ./zfs_create_pool.sh tank /dev/disk/by-id/scsi-0DO_Volume_volume-nyc1-01
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

# Check if pool already exists
if zpool list "$POOL_NAME" &> /dev/null; then
  echo -e "${RED}Error: Pool $POOL_NAME already exists${NC}"
  exit 1
fi

# Format the drive as GPT
echo -e "${BLUE}Formatting drive as GPT...${NC}"
wipefs -a "$DEVICE" &> /dev/null
parted "$DEVICE" -s mklabel gpt &> /dev/null

# Create the mountpoint directory
MOUNT_PATH="/zfs/$POOL_NAME"
mkdir -p "$MOUNT_PATH"

# Create the ZFS pool
echo -e "${BLUE}Creating ZFS pool $POOL_NAME with optimized settings...${NC}"
if zpool create -f \
  -O mountpoint="$MOUNT_PATH" \
  -O compression=lz4 \
  -O atime=off \
  -O sync=standard \
  -O aclinherit=passthrough \
  -O utf8only=on \
  -O normalization=formD \
  -O casesensitivity=sensitive \
  -o autoexpand=on \
  "$POOL_NAME" "$DEVICE"; then
  
  # Create a test dataset
  zfs create "$POOL_NAME/test" &> /dev/null || true
  
  echo -e "${GREEN}Pool $POOL_NAME created successfully${NC}"
  echo -e "Mountpoint: ${BLUE}$MOUNT_PATH${NC}"
  echo -e "Device: ${BLUE}$DEVICE${NC}"
  
  # Display pool status
  zpool status "$POOL_NAME"
  
  exit 0
else
  echo -e "${RED}Failed to create pool $POOL_NAME${NC}"
  exit 1
fi

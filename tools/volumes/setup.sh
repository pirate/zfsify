#!/usr/bin/env bash
# setup.sh
#
# Setup script to make all the component scripts executable and check permissions
#
# Usage: ./setup.sh
#
# This script will:
# 1. Make all component scripts executable
# 2. Check for root permissions
# 3. Check for required tools and offer to install them
#
# Execute this script first before running main.sh

set -e

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

# Colors
GREEN='\033[0;32m'
BLUE='\033[0;34m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
BOLD='\033[1m'
NC='\033[0m' # No Color

echo -e "${BOLD}${BLUE}=========================================${NC}"
echo -e "${BOLD}${BLUE}     ZFS Cloud Management Setup          ${NC}"
echo -e "${BOLD}${BLUE}=========================================${NC}"
echo ""

# Check if running as root
if [ "$(id -u)" -ne 0 ]; then
  echo -e "${RED}Error: This script must be run as root${NC}"
  echo -e "Please run again with: ${YELLOW}sudo $SCRIPT_DIR/setup.sh${NC}"
  exit 1
fi

# Make all component scripts executable
echo -e "${BLUE}Making all scripts executable...${NC}"
chmod +x "$SCRIPT_DIR"/*.sh "$SCRIPT_DIR"/../digitalocean/*.sh

# Check for required tools
echo -e "${BLUE}Checking for required tools...${NC}"

# Check for curl
if ! command -v curl &> /dev/null; then
  echo -e "${YELLOW}curl is not installed. Installing...${NC}"
  apt-get update -qq && apt-get install -y curl -qq
  echo -e "${GREEN}curl installed successfully${NC}"
else
  echo -e "${GREEN}✓ curl is installed${NC}"
fi

# Check for jq
if ! command -v jq &> /dev/null; then
  echo -e "${YELLOW}jq is not installed. Installing...${NC}"
  apt-get update -qq && apt-get install -y jq -qq
  echo -e "${GREEN}jq installed successfully${NC}"
else
  echo -e "${GREEN}✓ jq is installed${NC}"
fi

# Check for ZFS
if ! command -v zpool &> /dev/null; then
  echo -e "${YELLOW}ZFS is not installed. Installing...${NC}"
  apt-get update -qq && apt-get install -y zfsutils-linux -qq
  echo -e "${GREEN}ZFS installed successfully${NC}"
else
  echo -e "${GREEN}✓ ZFS is installed${NC}"
fi

# Check for parted
if ! command -v parted &> /dev/null; then
  echo -e "${YELLOW}parted is not installed. Installing...${NC}"
  apt-get update -qq && apt-get install -y parted -qq
  echo -e "${GREEN}parted installed successfully${NC}"
else
  echo -e "${GREEN}✓ parted is installed${NC}"
fi

# Check for DigitalOcean metadata service to verify we're on a DO droplet
if ! curl -s --connect-timeout 1 http://169.254.169.254/metadata/v1/id &> /dev/null; then
  echo -e "${YELLOW}Warning: DigitalOcean metadata service not available.${NC}"
  echo -e "${YELLOW}This might not be a DigitalOcean droplet or the metadata service is unavailable.${NC}"
  echo -e "${YELLOW}Some functionality may be limited.${NC}"
else
  echo -e "${GREEN}✓ Running on a DigitalOcean droplet${NC}"
fi

# Check for DO_API_TOKEN environment variable
if [ -z "$DO_API_TOKEN" ]; then
  echo -e "${YELLOW}Warning: DO_API_TOKEN environment variable is not set.${NC}"
  echo -e "${YELLOW}You will need to set this to create new volumes.${NC}"
  echo -e "${YELLOW}You can set it with: ${NC}${BOLD}export DO_API_TOKEN=your_token_here${NC}"
else
  echo -e "${GREEN}✓ DO_API_TOKEN environment variable is set${NC}"
fi

echo ""
echo -e "${GREEN}Setup completed successfully!${NC}"
echo -e "${BLUE}You can now run the volume wizard with: ${YELLOW}$SCRIPT_DIR/main.sh${NC}"
echo -e "${BOLD}${BLUE}=========================================${NC}"

#!/usr/bin/env bash
# terraform_get_droplet_metadata.sh
#
# Retrieves metadata about the current DigitalOcean droplet
#
# Usage: ./terraform_get_droplet_metadata.sh
#
# Output:
#   JSON object with droplet metadata
#
# Example output:
#   {
#     "droplet_id": "12345678",
#     "region": "nyc1",
#     "hostname": "ubuntu-s-1vcpu-1gb-nyc1-01"
#   }
#
# Notes:
#   - Must be run on a DigitalOcean droplet
#   - Requires curl (will be installed if missing)

set -e

# Check if curl is installed
if ! command -v curl &> /dev/null; then
  echo -e "\033[0;34mInstalling curl...\033[0m"
  apt-get update -qq && apt-get install -y curl -qq
fi

# Check if jq is installed
if ! command -v jq &> /dev/null; then
  echo -e "\033[0;34mInstalling jq...\033[0m"
  apt-get update -qq && apt-get install -y jq -qq
fi

# Check if running on a DigitalOcean droplet
if [ ! -f /etc/droplet-agent ] && [ ! -d /opt/digitalocean ]; then
  echo -e "\033[0;31mError: This script must be run on a DigitalOcean droplet\033[0m"
  exit 1
fi

# Get droplet ID from metadata service
DROPLET_ID=$(curl -s http://169.254.169.254/metadata/v1/id)
if [ -z "$DROPLET_ID" ]; then
  echo -e "\033[0;31mError: Failed to get droplet ID from metadata service\033[0m"
  exit 1
fi

# Get region from metadata service
REGION=$(curl -s http://169.254.169.254/metadata/v1/region)
if [ -z "$REGION" ]; then
  echo -e "\033[0;31mError: Failed to get region from metadata service\033[0m"
  exit 1
fi

# Get hostname from metadata service
HOSTNAME=$(curl -s http://169.254.169.254/metadata/v1/hostname)
if [ -z "$HOSTNAME" ]; then
  # Fallback to system hostname if metadata service doesn't provide it
  HOSTNAME=$(hostname -s)
fi

# Create and output JSON
jq -n \
  --arg droplet_id "$DROPLET_ID" \
  --arg region "$REGION" \
  --arg hostname "$HOSTNAME" \
  '{droplet_id: $droplet_id, region: $region, hostname: $hostname}'

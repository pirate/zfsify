#!/usr/bin/env bash
# terraform_list_volumes.sh
#
# Lists all DigitalOcean volumes in a specific region
# 
# Usage: ./terraform_list_volumes.sh [REGION]
#
# Arguments:
#   REGION - Optional DigitalOcean region (e.g., nyc1, sfo2)
#            If not provided, will be auto-detected from current droplet
#
# Output:
#   JSON array of volumes
#
# Example output:
#   [
#     {"id":"506f78a4-e098-11e5-ad9f-000f53306ae1","name":"volume-nyc1-01","region":"nyc1","size_gigabytes":100},
#     {"id":"506f78a4-e098-11e5-ad9f-000f53306ae2","name":"volume-nyc1-02","region":"nyc1","size_gigabytes":50}
#   ]
# 
# Requires:
#   - DO_API_TOKEN environment variable with DigitalOcean API token
#   - curl, jq

set -e

# Default region is empty (will be auto-detected if needed)
REGION=${1:-""}

# Check if DO_API_TOKEN is set
if [ -z "$DO_API_TOKEN" ]; then
  echo -e "\033[0;31mError: DO_API_TOKEN environment variable not set\033[0m"
  echo -e "Please set your DigitalOcean API token:"
  echo -e "export DO_API_TOKEN=your_token_here"
  exit 1
fi

# If region is not provided, try to auto-detect it
if [ -z "$REGION" ]; then
  # Check if curl is installed, if not install it
  if ! command -v curl &> /dev/null; then
    echo -e "\033[0;34mInstalling curl...\033[0m"
    apt-get update -qq && apt-get install -y curl -qq
  fi
  
  # Try to get region from metadata service
  REGION=$(curl -s http://169.254.169.254/metadata/v1/region)
  
  if [ -z "$REGION" ]; then
    echo -e "\033[0;31mError: Failed to auto-detect region. Please specify a region.\033[0m"
    exit 1
  fi
  
  echo -e "\033[0;34mAuto-detected region: ${REGION}\033[0m"
fi

# Check if jq is installed
if ! command -v jq &> /dev/null; then
  echo -e "\033[0;34mInstalling jq...\033[0m"
  apt-get update -qq && apt-get install -y jq -qq
fi

# List volumes in the specified region
response=$(curl -s -X GET \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $DO_API_TOKEN" \
  "https://api.digitalocean.com/v2/volumes?region=$REGION")

# Check if API request was successful
if echo "$response" | jq -e '.message' &> /dev/null; then
  error_message=$(echo "$response" | jq -r '.message')
  echo -e "\033[0;31mAPI Error: $error_message\033[0m"
  exit 1
fi

# Output formatted volume information
echo "$response" | jq '[.volumes[] | {id: .id, name: .name, region: .region.slug, size_gigabytes: .size_gigabytes}]'

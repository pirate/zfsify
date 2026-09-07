#!/bin/bash
set -e

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

# Colors for better output
GREEN='\033[0;32m'
BLUE='\033[0;34m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# Default values
VOLUME_SIZE=100
VOLUME_NAME="zfs-$(hostname -s)"
REGION=""
TF_DIR="/tmp/do-volume-terraform"

# Function to display script usage
usage() {
  echo -e "${BLUE}Usage:${NC} $0 [OPTIONS]"
  echo "Creates a DigitalOcean block storage volume and attaches it to the current droplet"
  echo 
  echo -e "${BLUE}Options:${NC}"
  echo "  -s, --size SIZE        Volume size in GB (default: $VOLUME_SIZE)"
  echo "  -n, --name NAME        Volume name (default: $VOLUME_NAME)"
  echo "  -r, --region REGION    DigitalOcean region (default: auto-detected from droplet)"
  echo "  -h, --help             Display this help and exit"
  exit 1
}

# Parse command line options
while [[ $# -gt 0 ]]; do
  case $1 in
    -s|--size)
      VOLUME_SIZE="$2"
      shift 2
      ;;
    -n|--name)
      VOLUME_NAME="$2"
      shift 2
      ;;
    -r|--region)
      REGION="$2"
      shift 2
      ;;
    -h|--help)
      usage
      ;;
    *)
      echo -e "${RED}Error:${NC} Unknown option: $1"
      usage
      ;;
  esac
done

echo -e "${GREEN}=========================================================${NC}"
echo -e "${GREEN}DigitalOcean Block Storage Volume Creation Script${NC}"
echo -e "${GREEN}=========================================================${NC}"

# Check if running on a DigitalOcean droplet
check_if_digitalocean() {
  if [ ! -f /etc/droplet-agent ] && [ ! -d /opt/digitalocean ]; then
    echo -e "${RED}Error: This script must be run on a DigitalOcean droplet.${NC}"
    exit 1
  fi
}

# Install necessary packages
install_prerequisites() {
  echo -e "\n${BLUE}Checking and installing prerequisites...${NC}"
  
  # Install curl if not already installed
  if ! command -v curl &>/dev/null; then
    echo "Installing curl..."
    apt-get update -qq && apt-get install -y curl
  fi
  
  # Install jq if not already installed
  if ! command -v jq &>/dev/null; then
    echo "Installing jq..."
    apt-get update -qq && apt-get install -y jq
  fi
  
  # Install Terraform if not already installed
  if ! command -v terraform &>/dev/null; then
    echo "Installing Terraform..."
    apt-get update -qq && apt-get install -y gnupg software-properties-common
    
    # Import HashiCorp GPG key
    wget -O- https://apt.releases.hashicorp.com/gpg | gpg --dearmor | tee /usr/share/keyrings/hashicorp-archive-keyring.gpg >/dev/null
    
    # Add HashiCorp repository
    echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $(lsb_release -cs) main" | tee /etc/apt/sources.list.d/hashicorp.list
    
    # Install Terraform
    apt-get update -qq && apt-get install -y terraform
  fi
}

# Get DigitalOcean API token
get_api_token() {
  echo -e "\n${BLUE}Setting up DigitalOcean API access...${NC}"
  
  # Check if DO_API_TOKEN is already set
  if [ -z "$DO_API_TOKEN" ]; then
    echo -e "DigitalOcean API Token not found in environment variables."
    echo -e "You can generate an API token at: ${GREEN}https://cloud.digitalocean.com/account/api/tokens${NC}"
    echo -e "The token requires read and write permissions."
    echo -n "Please enter your DigitalOcean API Token: "
    read -s DO_API_TOKEN
    echo
    
    if [ -z "$DO_API_TOKEN" ]; then
      echo -e "${RED}Error: API Token cannot be empty${NC}"
      exit 1
    fi
  else
    echo "Using DigitalOcean API Token from environment variables."
  fi
}


# Check if volume with same name exists and get a unique name if needed
check_and_get_unique_name() {
  echo -e "\n${BLUE}Checking if volume '$VOLUME_NAME' already exists in region '$REGION'...${NC}"
  
  local response=$(curl -s -X GET \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer $DO_API_TOKEN" \
    "https://api.digitalocean.com/v2/volumes?name=$VOLUME_NAME&region=$REGION")
  
  # Check if volumes exist with this name
  local volumes_count=$(echo "$response" | jq '.volumes | length')
  
  if [ "$volumes_count" -gt 0 ]; then
    echo -e "${RED}Error: A volume with the name '$VOLUME_NAME' already exists in region '$REGION'.${NC}"
    
    # Keep prompting until we get a unique name
    local original_name="$VOLUME_NAME"
    local name_is_unique=false
    
    while [ "$name_is_unique" = false ]; do
      echo -n "Please enter a different volume name (or press Enter for auto-generated name): "
      read new_name
      
      if [ -z "$new_name" ]; then
        new_name="${original_name}-$(date +%s)"
        echo -e "Using auto-generated name: $new_name"
      fi
      
      # Check if the new name exists
      response=$(curl -s -X GET \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer $DO_API_TOKEN" \
        "https://api.digitalocean.com/v2/volumes?name=$new_name&region=$REGION")
      
      volumes_count=$(echo "$response" | jq '.volumes | length')
      
      if [ "$volumes_count" -eq 0 ]; then
        VOLUME_NAME="$new_name"
        name_is_unique=true
      else
        echo -e "${RED}Error: A volume with the name '$new_name' also exists in region '$REGION'.${NC}"
      fi
    done
  fi
  
  echo -e "Volume name '$VOLUME_NAME' is available for creation."
}

# Get current droplet metadata
get_droplet_metadata() {
  echo -e "\n${BLUE}Getting current droplet information...${NC}"
  
  # Get droplet ID from metadata service
  DROPLET_ID=$(curl -s http://169.254.169.254/metadata/v1/id)
  
  if [ -z "$DROPLET_ID" ]; then
    echo -e "${RED}Error: Failed to get droplet ID from metadata service${NC}"
    exit 1
  fi
  
  echo "Current Droplet ID: $DROPLET_ID"
  
  # Get region from metadata if not specified
  if [ -z "$REGION" ]; then
    REGION=$(curl -s http://169.254.169.254/metadata/v1/region)
    echo "Detected region: $REGION"
  else
    echo "Using specified region: $REGION"
  fi
}

# Create Terraform configuration files
create_terraform_files() {
  echo -e "\n${BLUE}Creating Terraform configuration...${NC}"
  
  # Create temporary directory for Terraform files
  mkdir -p "$TF_DIR"
  
  # Create main.tf
  cat > "$TF_DIR/main.tf" << EOF
terraform {
  required_version = ">= 1.1.1"

  required_providers {
    digitalocean = {
      source  = "digitalocean/digitalocean"
      version = "~> 2.0"
    }
  }
}

provider "digitalocean" {
  token = var.do_token
}

# Variables
variable "do_token" {
  description = "DigitalOcean API Token"
  type        = string
  sensitive   = true
}

variable "region" {
  description = "Region where resources will be created"
  type        = string
}

variable "volume_size" {
  description = "Size of the block storage volume in GB"
  type        = number
}

variable "volume_name" {
  description = "Name of the block storage volume"
  type        = string
}

variable "droplet_id" {
  description = "ID of the droplet to attach the volume to"
  type        = string
}

# Create a new block storage volume
resource "digitalocean_volume" "storage" {
  region      = var.region
  name        = var.volume_name
  size        = var.volume_size
  description = "Block storage volume for additional storage"
  # No initial filesystem type specified as requested
}

# Attach the volume to the droplet
resource "digitalocean_volume_attachment" "storage_attachment" {
  droplet_id = var.droplet_id
  volume_id  = digitalocean_volume.storage.id
}

# Output the volume details
output "volume_id" {
  value = digitalocean_volume.storage.id
}

output "volume_name" {
  value = digitalocean_volume.storage.name
}

output "volume_size" {
  value = digitalocean_volume.storage.size
}

output "attachment_status" {
  value = "Volume \${digitalocean_volume.storage.name} attached to droplet ID \${var.droplet_id}"
}
EOF

  # Create terraform.tfvars
  cat > "$TF_DIR/terraform.tfvars" << EOF
do_token    = "${DO_API_TOKEN}"
region      = "${REGION}"
volume_size = ${VOLUME_SIZE}
volume_name = "${VOLUME_NAME}"
droplet_id  = "${DROPLET_ID}"
EOF
}


# Run Terraform to create and attach the volume
run_terraform() {
  echo -e "\n${BLUE}Running Terraform to create and attach volume...${NC}"
  
  cd "$TF_DIR"
  
  # Initialize Terraform
  echo "Initializing Terraform..."
  terraform init -input=false
  
  # Check for existing state - if exists, this is a potential problem
  if [ -f "${TF_DIR}/terraform.tfstate" ]; then
    echo -e "${RED}Warning: Existing Terraform state found. Starting with a fresh state to avoid modifying existing resources.${NC}"
    rm -f "${TF_DIR}/terraform.tfstate"
  fi
  
  # Create execution plan
  echo "Creating Terraform plan..."
  terraform plan -input=false -out=tfplan
  
  # Apply the Terraform plan
  echo "Applying Terraform plan..."
  terraform apply -input=false tfplan
  
  # Extract and display the results
  VOLUME_ID=$(terraform output -raw volume_id)
  VOLUME_NAME=$(terraform output -raw volume_name)
  VOLUME_SIZE=$(terraform output -raw volume_size)
  
  echo -e "\n${GREEN}Success!${NC}"
  echo -e "Volume ID: ${BLUE}$VOLUME_ID${NC}"
  echo -e "Volume Name: ${BLUE}$VOLUME_NAME${NC}"
  echo -e "Volume Size: ${BLUE}${VOLUME_SIZE}GB${NC}"
  echo -e "Region: ${BLUE}$REGION${NC}"
  echo -e "Attached to Droplet ID: ${BLUE}$DROPLET_ID${NC}"
  
  # Get device path
  echo -e "\n${BLUE}Checking for the device path...${NC}"
  echo "The volume should be available at this path:"
  echo "/dev/disk/by-id/scsi-0DO_Volume_${VOLUME_NAME}"
  
}

# Cleanup temp files
cleanup() {
  echo -e "\n${BLUE}Cleaning up temporary files...${NC}"
  # Uncomment if you want to remove the Terraform files
  # rm -rf "$TF_DIR"
  echo "Terraform files are kept at $TF_DIR for reference."
}

# Main execution
main() {
  # Check if running as root
  if [ "$(id -u)" -ne 0 ]; then
    echo -e "${RED}Error: This script must be run as root${NC}"
    exit 1
  fi
  
  check_if_digitalocean
  install_prerequisites
  get_api_token
  get_droplet_metadata
  check_and_get_unique_name
  create_terraform_files
  run_terraform
  cleanup
  
  echo -e "\n${GREEN}Volume creation and attachment completed successfully!${NC}"

  exec "$SCRIPT_DIR/../volumes/zfs-wizard.sh"
}

# Run the main function
main

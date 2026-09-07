#!/usr/bin/env bash

### Bash Environment Setup
# http://redsymbol.net/articles/unofficial-bash-strict-mode/
# https://www.gnu.org/software/bash/manual/html_node/The-Set-Builtin.html
# set -o xtrace
# set -x
# shopt -s nullglob
set -o errexit
set -o errtrace
# set -o nounset
set -o pipefail
# IFS=$'\n'

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$SCRIPT_DIR/$(basename -- "${BASH_SOURCE[0]}")"


# Function to handle interruption
cleanup() {
  # Kill any background processes we might be monitoring
  if [[ -n "$progress_pid" && -n "$monitored_pid" ]]; then
    kill $monitored_pid 2>/dev/null
    kill $progress_pid 2>/dev/null
  fi
  
  echo -e "\n${RED}Operation interrupted by user${NC}"
  exit 1
}

# Set trap for Ctrl+C
trap cleanup SIGINT SIGTERM

# Function to display progress bar
progress() {
  declare -i pid=$1
  local delay=0.1
  local spinstr='|/-\'
  
  # Store PIDs in global variables so the trap can access them
  monitored_pid=$pid
  progress_pid=$
  
  while kill -0 $pid 2>/dev/null; do
    local temp=${spinstr#?}
    printf " [%c]  " "$spinstr"
    local spinstr=$temp${spinstr%"$temp"}
    sleep $delay
    printf "\b\b\b\b\b\b"
  done
  
  # Clear progress variables when done
  monitored_pid=""
  progress_pid=""
  printf "    \b\b\b\b"
}

# Install required packages
echo "📦 Installing required packages (gawk fio zfsutils-linux parted pv jq ncurses-bin bc)..."
apt-get update -qq > /dev/null 2>&1 &
pid=$!
progress $pid
wait $pid

apt-get install -y gawk fio zfsutils-linux parted pv jq ncurses-bin bc > /dev/null 2>&1 &
pid=$!
progress $pid
wait $pid

# Colors and formatting
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# Function for colored echo
cecho() {
  # Diagnostics must not contaminate the device path returned by find_new_drive.
  echo -e "$*${NC}" >&2
}

# Function for headers
header() {
  echo ""
  cecho "${BOLD}${BLUE}=== $* ==="
}

# Function for success messages
success() {
  cecho "${GREEN}✅  $*"
}

# Function for error messages
error() {
  cecho "${RED}❌  $*"
  exit 1
}

# Function for warning messages
warn() {
  cecho "${YELLOW}⚠️  $*"
}

# Function for info messages
info() {
  cecho "${CYAN}ℹ️  $*"
}

debug() {
  cecho "${PURPLE}    $*"
}

# Function for confirmation prompts
confirm() {
  local prompt=$1
  local default=${2:-Y}
  
  if [[ $default == "Y" ]]; then
    local options="[Y/n]"
  else
    local options="[y/N]"
  fi
  
  echo ""
  cecho "${YELLOW}${prompt} ${options}"
  read -r response
  
  if [[ -z $response ]]; then
    response=$default
  fi
  
  if [[ $response =~ ^[Yy]$ ]]; then
    return 0
  else
    return 1
  fi
}

# Function to format size
format_size() {
  local size=$1
  if [[ $size -gt 1073741824 ]]; then
    printf "%.2f TB" $(echo "$size/1073741824" | bc -l)
  elif [[ $size -gt 1048576 ]]; then
    printf "%.2f GB" $(echo "$size/1048576" | bc -l)
  elif [[ $size -gt 1024 ]]; then
    printf "%.2f MB" $(echo "$size/1024" | bc -l)
  else
    printf "%d KB" $size
  fi
}

# Display welcome message
echo ""
cecho "${BOLD}${PURPLE}🧙 Welcome to ZFS Cloud Wizard${NC}"
echo ""
cecho "${CYAN}This script automates setting up Cloud Block Storage (e.g. EBS, DigialOcean, GCP, etc.) using ZFS on a VPS.${NC}"
echo ""

# Get pool name and options
poolname="${1:-tank}"
add_new_stripe="${2}"
add_vdev_mirror="${3}"

header "Checking System Configuration"

# Check if running as root
if [[ $EUID -ne 0 ]]; then
  error "This script must be run as root"
fi

# Check if ZFS is installed
if ! command -v zpool &> /dev/null; then
  error "ZFS is not installed. Please install zfsutils-linux package"
fi

# Find new un# Function to format size
format_size() {
  local size=$1
  if [[ $size -gt 1073741824 ]]; then
    printf "%.2f TB" $(echo "$size/1073741824" | bc -l)
  elif [[ $size -gt 1048576 ]]; then
    printf "%.2f GB" $(echo "$size/1048576" | bc -l)
  elif [[ $size -gt 1024 ]]; then
    printf "%.2f MB" $(echo "$size/1024" | bc -l)
  else
    printf "%d KB" $size
  fi
}

# Find new unformatted drives
header "Scanning for available drives"

# This function scans for new unformatted drives and picks the largest one
find_new_drive() {
  debug "Scanning for SCSI drives..."

  # Get all SCSI drives
  all_drives=$(ls /dev/disk/by-id/scsi-* 2>/dev/null | grep -v "part[0-9]" || echo "")
  
  debug "Found $(echo "$all_drives" | wc -l) SCSI drives to check..."

  # If no SCSI drives found, try to use regular drives
  if [[ -z "$all_drives" ]]; then
    warn "No SCSI drives found, falling back to regular block devices"
    all_drives=$(lsblk -dpno NAME | grep -v 'loop\|sr0\|zd\|[0-9]$')
  fi
  
  debug "Found $(echo "$all_drives" | wc -l) drives to check..."

  # Find drives with no partitions
  local candidate_drives=()
  local drive_sizes=()
  
  for drive in $all_drives; do
    # Get real path of the drive
    local real_drive=$(readlink -f "$drive")
	local real_name=$(basename "$real_drive")
	local name=$(basename "$drive")

	# Skip if this is a partition (has "-part" in the name or ends with a number)
    if [[ "$drive" =~ -part[0-9]+ || "$drive" =~ [0-9]$ ]]; then
	  debug "Skipping drive: $drive (is a partition)"
      continue
    fi
    
    
    
    # Skip if real path is a partition (ends with a number)
    if [[ "$(basename "$real_drive")" =~ [0-9]$ ]]; then
	  debug "Skipping drive: $drive (is a partition)"
      continue
    fi
    
    # Skip if drive is used by ZFS
    if zpool status | grep -qE "($real_name)|($name)"; then
	  debug "Skipping drive: $drive (is a ZFS vdev)"
      continue
    fi
    
    # Skip if drive is part of any ZFS pool (more thorough check)
    if zpool list -v | grep -qE "($real_name)|($name)"; then
	  debug "Skipping drive: $drive (is part of ZFS pool)"
      continue
    fi
    
    # Skip if drive has partitions
    if [[ $(lsblk -no NAME "$real_drive" | wc -l) -gt 1 ]] || [[ $(lsblk -no NAME "$drive" | wc -l) -gt 1 ]]; then
	  debug "Skipping drive: $drive (has partitions)"
      continue
    fi
    
    # Check for existing partition table or filesystem signatures
    if sfdisk -d "$real_drive" 2>/dev/null | grep -q "^/"; then
	  debug "Skipping drive: $drive (has partition table)"
      continue
    fi
    
    # Check if drive has any filesystem signature
    if wipefs -n "$real_drive" 2>/dev/null | grep -q -E 'filesystem|partition-table'; then
	  debug "Skipping drive: $drive (has filesystem signature)"
      continue
    fi
    
    # Double check that this is a whole disk and not a partition
    if lsblk -dno TYPE "$real_drive" | grep -q "part"; then
	  debug "Skipping drive: $drive (has partition)"
      continue
    fi
    
    # Get drive size in KB
    local size=$(lsblk -bno SIZE "$real_drive" 2>/dev/null | head -1)
    candidate_drives+=("$drive")
    drive_sizes+=("$size")
  done
  
  # If no candidate drives found
  if [[ ${#candidate_drives[@]} -eq 0 ]]; then
	# walk the user through creating a new block device in their Cloud Provider
	warn "${YELLOW}No unformatted drives found${NC}"
	info "Please create a new block device in your Cloud Provider and then press [Enter] to continue"
	info "Example: AWS - https://console.aws.amazon.com/ec2/volumes/"
	info "Example: GCP - https://console.cloud.google.com/compute/disks"
	info "Example: Linode - https://cloud.linode.com/volumes"
	info "Example: Vultr - https://my.vultr.com/deploy/"
	info "Example: OVH - https://www.ovh.com/manager/cloud/index.html"
	
	info "Example: DigitalOcean - https://cloud.digitalocean.com/volumes"
	info "1. Go to https://cloud.digitalocean.com/volumes (or the equivalent Block Storage Admin interface for your Cloud Provider)"
	info "2. Click the 'Create Volume' button"
	info "3. Select the size you want the new volume to be"
	info "4. Select the server you want to attach the volume to"
	info "5. Choose a name for the volume: $BOLD$poolname$NC"
	info "6. IMPORTANT: Select $BOLD'Manually Format & Mount'$RED not ext4/XFS$NC"
	info "7. Click the 'Create Volume' button"
	info ""
	warn "... wait for the volume to be created..."
	info ""
	success "8. Press [Enter] once the volume is created..."
	read -r

	# re-run the script to scan for the new drive
    exec "$SCRIPT" "$poolname" "$add_new_stripe" "$add_vdev_mirror"
  fi
  
  # Find the largest drive
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

new_drive=$(find_new_drive)

if [[ -z "$new_drive" ]]; then
    error "Failed to find a suitable drive"
else
	debug "Calculating drive size... $new_drive"
fi

# Get actual disk path and size
real_drive_path=$(readlink -f "$new_drive")
drive_size=$(lsblk -bno SIZE "$real_drive_path" | head -1)
formatted_size=$(format_size "$drive_size")

info "Found drive: ${BOLD}$new_drive${NC} (${BOLD}$formatted_size${NC})"
info "Physical path: ${BOLD}$real_drive_path${NC}"

# Prompt the user to confirm
if ! confirm "Are you sure you want to ERASE this drive and add it to '$poolname'?"; then
  error "Operation cancelled by user"
fi

# Format the drive as GPT
header "Formatting drive as GPT"
(
  echo "Wiping existing filesystem signatures..."
  wipefs -a "$real_drive_path"
  echo "Creating GPT label..."
  parted "$real_drive_path" -s mklabel gpt
) > /dev/null 2>&1 &
pid=$!
progress $pid
wait $pid

if [ $? -ne 0 ]; then
  error "Failed to format the drive"
fi

success "Drive formatted successfully"

# Check if the pool already exists
if zpool list "$poolname" > /dev/null 2>&1; then
  header "Adding drive to existing pool '$poolname'"

  # Enable autoexpand on the pool
  info "Enabling autoexpand on pool"
  zpool set autoexpand=on "$poolname"

  if [[ "$add_vdev_mirror" ]]; then
    # Add it as a new mirror to an existing vdev
    info "Adding as mirror to existing vdev: $add_vdev_mirror"
    
    # Find the drive to mirror from the provided vdev name or find automatically
    if [[ "$add_vdev_mirror" == "--auto" ]]; then
      drive_to_mirror=$(zpool status "$poolname" | awk '/NAME/,/errors:/' | awk '/scsi-/{print $1; exit}')
      if [[ -z "$drive_to_mirror" ]]; then
        error "Failed to automatically find a drive to mirror"
      fi
      info "Automatically selected drive to mirror: ${BOLD}$drive_to_mirror${NC}"
    else
      drive_to_mirror="$add_vdev_mirror"
    fi
    
    info "Creating mirror with ${BOLD}$drive_to_mirror${NC}"
    zpool attach "$poolname" "$drive_to_mirror" "$new_drive" > /dev/null 2>&1 &
    pid=$!
    progress $pid
    wait $pid
    
    if [ $? -ne 0 ]; then
      error "Failed to attach mirror"
    fi
    
    success "Mirror vdev added successfully"
  else
    # Add it as a new stripe
    info "Adding as new stripe"
    zpool add "$poolname" "$new_drive" > /dev/null 2>&1 &
    pid=$!
    progress $pid
    wait $pid
    
    if [ $? -ne 0 ]; then
      error "Failed to add stripe"
    fi
    
    success "Stripe vdev added successfully"
  fi

  # Expand the pool
  info "Expanding pool"
  zpool online -e "$poolname" "$new_drive" > /dev/null 2>&1
else
  # Create a new pool
  header "Creating new ZFS pool '$poolname'"
  
  # Create the mountpoint directory
  mkdir -p "/zfs/$poolname"
  
  # Create the pool
  info "Creating pool with optimized settings"
  (
    zpool create -f \
      -O mountpoint="/zfs/$poolname" \
      -O compression=lz4 \
      -O atime=off \
      -O sync=standard \
      -O aclinherit=passthrough \
      -O utf8only=on \
      -O normalization=formD \
      -O casesensitivity=sensitive \
      -o autoexpand=on \
      "$poolname" "$new_drive"
    
    # Create a test dataset
    zfs create "$poolname/test"
  ) > /dev/null 2>&1 &
  pid=$!
  progress $pid
  wait $pid
  
  if [ $? -ne 0 ]; then
    error "Failed to create pool"
  fi
  
  success "Pool created successfully"
fi

# Run speed test
header "Running performance test"

info "Testing sequential read/write speed (this may take a minute)..."
speedtest_result=$(
  cd "/zfs/$poolname" && \
  fio --name=seq_test --ioengine=libaio --rw=readwrite --bs=4M --direct=1 \
      --size=1G --numjobs=4 --iodepth=16 --group_reporting \
      --runtime=30 --time_based --output-format=json
)

# Parse the results
peak_read=$(echo "$speedtest_result" | jq '.jobs[0].read.bw_max / 1024' | cut -d. -f1)
peak_write=$(echo "$speedtest_result" | jq '.jobs[0].write.bw_max / 1024' | cut -d. -f1)
avg_read=$(echo "$speedtest_result" | jq '.jobs[0].read.bw / 1024' | cut -d. -f1)
avg_write=$(echo "$speedtest_result" | jq '.jobs[0].write.bw / 1024' | cut -d. -f1)

# If values are empty, fallback to a simpler test
if [[ -z "$peak_read" || -z "$peak_write" || -z "$avg_read" || -z "$avg_write" ]]; then
  warn "Advanced IO test failed, running simple test..."
  # Clean up any files from the previous test
  rm -f "/zfs/$poolname/testfile"
  
  # Simple read test
  dd if=/dev/zero of="/zfs/$poolname/testfile" bs=1M count=1024 conv=fdatasync 2>&1 | \
    grep -o "[0-9.]* MB/s" | awk '{print $1}' > /tmp/write_speed
  avg_write=$(cat /tmp/write_speed)
  peak_write=$avg_write
  
  # Simple write test
  dd if="/zfs/$poolname/testfile" of=/dev/null bs=1M 2>&1 | \
    grep -o "[0-9.]* MB/s" | awk '{print $1}' > /tmp/read_speed
  avg_read=$(cat /tmp/read_speed)
  peak_read=$avg_read
  
  # Clean up
  rm -f "/zfs/$poolname/testfile" /tmp/write_speed /tmp/read_speed
fi

# Show a summary
header "ZFS Pool Summary"

# Display pool status with color highlighting
zpool status "$poolname" | grep --color=always "${new_drive}\|$"

echo ""
cecho "${CYAN}Pool:        ${BOLD}$poolname${NC}"
cecho "${CYAN}Mountpoint:  ${BOLD}/zfs/$poolname${NC}"
cecho "${CYAN}New Drive:   ${BOLD}$new_drive${NC}"
cecho "${CYAN}Drive Size:  ${BOLD}$formatted_size${NC}"
echo ""
cecho "${CYAN}Pool Speed:  ${BOLD}"
echo -e "  ↗️ Read:  ${GREEN}${peak_read} MB/s peak${NC}, ${YELLOW}${avg_read} MB/s avg${NC}"
echo -e "  ↘️ Write: ${GREEN}${peak_write} MB/s peak${NC}, ${YELLOW}${avg_write} MB/s avg${NC}"

header "Usage Examples"
echo "To create a new ZFS dataset:"
echo -e "${YELLOW}  zfs create $poolname/mynewdataset${NC}"
echo ""
echo "To set specific options on a dataset:"
echo -e "${YELLOW}  zfs set compression=zstd $poolname/mynewdataset${NC}"
echo ""
echo "To check used space:"
echo -e "${YELLOW}  zfs list $poolname${NC}"
echo ""
echo "To back up this pool:"
echo -e "${YELLOW}  zfs snapshot -r $poolname@backup-$(date +%Y%m%d)${NC}"
echo ""

success "ZFS Cloud Wizard completed successfully!"

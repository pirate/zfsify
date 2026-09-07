#!/usr/bin/env bash
# speedtest.sh
#
# Performs a read/write speed test on a ZFS pool using dd
#
# Usage: ./speedtest.sh POOL_NAME
#
# Arguments:
#   POOL_NAME : Name of the ZFS pool to test
#
# Output:
#   Read and write speeds in MB/s
#
# Example:
#   ./speedtest.sh tank
#
# Requires:
#   - zfsutils-linux

set -e

# Colors
GREEN='\033[0;32m'
BLUE='\033[0;34m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# Parse arguments
POOL_NAME="$1"

# Validate arguments
if [ -z "$POOL_NAME" ]; then
  echo -e "${RED}Error: Pool name is required${NC}"
  echo -e "Usage: $0 POOL_NAME"
  exit 1
fi

# Check if zfs is installed
if ! command -v zpool &> /dev/null; then
  echo -e "${BLUE}Installing ZFS utilities...${NC}"
  apt-get update -qq && apt-get install -y zfsutils-linux -qq
fi

# Check if pool exists
if ! zpool list "$POOL_NAME" &> /dev/null; then
  echo -e "${RED}Error: Pool $POOL_NAME does not exist${NC}"
  exit 1
fi

# Create a test file path
TEST_FILE="/zfs/$POOL_NAME/speedtest_file"

# Make sure to clean up on exit
trap "rm -f $TEST_FILE" EXIT

# Function to convert bytes per second to megabytes per second
to_mb_per_sec() {
  echo "scale=2; $1 / 1048576" | bc
}

# Function to run the test
run_test() {
  local block_size="$1"
  local count="$2"
  local test_type="$3"
  
  echo -e "${BLUE}Running $test_type test with ${CYAN}bs=${block_size}${BLUE} and ${CYAN}count=${count}${BLUE}...${NC}"
  
  if [ "$test_type" = "write" ]; then
    # Write test
    echo -n "${YELLOW}Write speed: ${NC}"
    write_output=$(dd if=/dev/zero of="$TEST_FILE" bs="$block_size" count="$count" conv=fdatasync 2>&1)
    write_speed=$(echo "$write_output" | grep -o "[0-9.]* MB/s" || echo "0 MB/s")
    echo -e "${GREEN}$write_speed${NC}"
    
    # Extract just the numeric part
    write_speed_num=$(echo "$write_speed" | sed 's/ MB\/s//')
    echo "$write_speed_num"
  else
    # Read test - first we need to clear caches
    echo -e "${BLUE}Clearing caches...${NC}"
    sync
    echo 3 > /proc/sys/vm/drop_caches
    
    # Read test
    echo -n "${YELLOW}Read speed: ${NC}"
    read_output=$(dd if="$TEST_FILE" of=/dev/null bs="$block_size" 2>&1)
    read_speed=$(echo "$read_output" | grep -o "[0-9.]* MB/s" || echo "0 MB/s")
    echo -e "${GREEN}$read_speed${NC}"
    
    # Extract just the numeric part
    read_speed_num=$(echo "$read_speed" | sed 's/ MB\/s//')
    echo "$read_speed_num"
  fi
}

# Print header
echo -e "\n${BOLD}${BLUE}========== ZFS Pool Speed Test ==========${NC}"
echo -e "${CYAN}Pool: ${BOLD}$POOL_NAME${NC}"
echo -e "${CYAN}Mount: ${BOLD}/zfs/$POOL_NAME${NC}"
echo

# Run multiple tests with different block sizes
# First run a large write test
echo -e "${BOLD}Large File Test (1GB)${NC}"
large_write=$(run_test "1M" "1024" "write")
large_read=$(run_test "1M" "1024" "read")

# Run a small block test 
echo -e "\n${BOLD}Small Block Test (4K blocks, 100MB total)${NC}"
small_write=$(run_test "4K" "25600" "write")
small_read=$(run_test "4K" "25600" "read")

# Summary
echo -e "\n${BOLD}${BLUE}========== Speed Test Summary ==========${NC}"
echo -e "${CYAN}Pool: ${BOLD}$POOL_NAME${NC}"

echo -e "\n${BOLD}Sequential I/O Performance:${NC}"
echo -e "  ↗️  ${BOLD}Read:${NC}  ${GREEN}$large_read MB/s${NC} (1M blocks)"
echo -e "  ↘️  ${BOLD}Write:${NC} ${GREEN}$large_write MB/s${NC} (1M blocks)"

echo -e "\n${BOLD}Small Block Performance:${NC}"
echo -e "  ↗️  ${BOLD}Read:${NC}  ${GREEN}$small_read MB/s${NC} (4K blocks)"
echo -e "  ↘️  ${BOLD}Write:${NC} ${GREEN}$small_write MB/s${NC} (4K blocks)"

echo -e "\n${BOLD}${BLUE}=====================================${NC}"

# Clean up
rm -f "$TEST_FILE"

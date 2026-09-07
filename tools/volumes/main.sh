#!/usr/bin/env bash
# Compatibility entry point for the attached-volume ZFS wizard.
# Usage: main.sh [--poolname NAME]
# Provider provisioning is a separate command: ../digitalocean/terraform.sh.
# This wizard formats an attached disk; it does not preserve an existing filesystem.
set -e

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
POOL_NAME=tank
while [[ $# -gt 0 ]]; do
  case "$1" in
    --poolname)
      if [[ $# -lt 2 || -z "$2" ]]; then
        echo 'Error: --poolname requires a name.' >&2
        exit 2
      fi
      POOL_NAME=$2
      shift 2
      ;;
    -h|--help)
      printf 'Usage: %s [--poolname NAME]\n' "$0"
      echo 'Launches the attached-volume ZFS wizard; selected disk contents are erased.'
      echo 'Create cloud volumes separately with tools/digitalocean/terraform.sh.'
      exit 0
      ;;
    *)
      printf 'Error: unknown option: %s\n' "$1" >&2
      exit 2
      ;;
  esac
done

exec "$SCRIPT_DIR/zfs-wizard.sh" "$POOL_NAME"

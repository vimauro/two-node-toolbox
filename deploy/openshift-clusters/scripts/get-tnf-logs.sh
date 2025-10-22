#!/bin/bash

# Get the directory where this script is located
SCRIPT_DIR=$(dirname "$0")
# Get the deploy directory (two levels up from scripts)
DEPLOY_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
# Get the repository root directory (one level up from deploy)
REPO_ROOT="$(cd "${DEPLOY_DIR}/.." && pwd)"

set -o nounset
set -o errexit
set -o pipefail

# Parse optional boot parameter (default: -1 for current boot only)
JOURNALCTL_BOOTS="${1:--1}"

# Validate boots parameter is a number
if ! [[ "$JOURNALCTL_BOOTS" =~ ^-?[0-9]+$ ]]; then
    echo "Usage: $0 [journalctl_boots]"
    echo ""
    echo "Arguments:"
    echo "  journalctl_boots - Number of boots to collect (default: -1)"
    echo "                     -1: Current boot only (default)"
    echo "                      0: All boots"
    echo "                      N: Specific number of most recent boots"
    echo ""
    echo "Examples:"
    echo "  $0        # Collect logs from current boot only"
    echo "  $0 0      # Collect logs from all boots"
    echo "  $0 -2     # Collect logs from previous boot"
    exit 1
fi

# Check if inventory.ini exists in the openshift-clusters directory
if [[ ! -f "${DEPLOY_DIR}/openshift-clusters/inventory.ini" ]]; then
    echo "Error: inventory.ini not found in ${DEPLOY_DIR}/openshift-clusters/"
    echo "Please ensure the inventory file is properly configured."
    exit 1
fi

if [[ "$JOURNALCTL_BOOTS" == "-1" ]]; then
    echo "Collecting pacemaker and etcd logs from cluster nodes (current boot only)..."
elif [[ "$JOURNALCTL_BOOTS" == "0" ]]; then
    echo "Collecting pacemaker and etcd logs from cluster nodes (all boots)..."
else
    echo "Collecting pacemaker and etcd logs from cluster nodes (boot offset: $JOURNALCTL_BOOTS)..."
fi

# Navigate to the openshift-clusters directory and run the log collection playbook
cd "${DEPLOY_DIR}/openshift-clusters"

# Run the log collection playbook with boot parameter
if ansible-playbook ../../helpers/collect-tnf-logs.yml -i inventory.ini -e "journalctl_boots=${JOURNALCTL_BOOTS}"; then
    echo ""
    # Get the most recent logs directory from repository root
    LATEST_LOG_DIR=$(find "${REPO_ROOT}/logs" -maxdepth 1 -type d -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -1 | cut -d' ' -f2- | xargs basename 2>/dev/null)
    if [[ -n "${LATEST_LOG_DIR}" ]]; then
        echo "✓ Logs collected successfully!"
        echo ""
        echo "Logs location: ${REPO_ROOT}/logs/${LATEST_LOG_DIR}"
    else
        echo "✓ Log collection completed, but could not determine logs directory"
    fi
else
    echo "Error: Log collection failed!"
    echo "Check the Ansible output for more details."
    exit 1
fi

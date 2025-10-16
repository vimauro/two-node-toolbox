#!/bin/bash

# Get the directory where this script is located
SCRIPT_DIR=$(dirname "$0")
# Get the deploy directory (two levels up from scripts)
DEPLOY_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"

set -o nounset
set -o errexit
set -o pipefail

# Check if inventory.ini exists in the openshift-clusters directory
if [[ ! -f "${DEPLOY_DIR}/openshift-clusters/inventory.ini" ]]; then
    echo "Error: inventory.ini not found in ${DEPLOY_DIR}/openshift-clusters/"
    echo "Please ensure the inventory file is properly configured."
    exit 1
fi

echo "Collecting pacemaker and etcd logs from cluster nodes..."

# Navigate to the openshift-clusters directory and run the log collection playbook
cd "${DEPLOY_DIR}/openshift-clusters"

# Run the log collection playbook
if ansible-playbook ../../helpers/collect-tnf-logs.yml -i inventory.ini; then
    echo ""
    # Get the most recent logs directory
    LATEST_LOG_DIR=$(ls -t "${DEPLOY_DIR}/logs" 2>/dev/null | head -1)
    if [[ -n "${LATEST_LOG_DIR}" ]]; then
        echo "✓ Logs collected successfully!"
        echo ""
        echo "Logs location: ${DEPLOY_DIR}/logs/${LATEST_LOG_DIR}"
    else
        echo "✓ Log collection completed, but could not determine logs directory"
    fi
else
    echo "Error: Log collection failed!"
    echo "Check the Ansible output for more details."
    exit 1
fi

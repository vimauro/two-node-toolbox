#!/bin/bash

SCRIPT_DIR=$(dirname "$0")
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/common.sh"

set -o nounset
set -o errexit
set -o pipefail

# Start instance with capacity error detection
# Provides actionable guidance if start fails due to insufficient capacity
function start_instance_with_capacity_check() {
    local instance_id="$1"
    local region="$2"

    local output
    set +e
    output=$(aws --region "${region}" ec2 start-instances --instance-ids "${instance_id}" --no-cli-pager 2>&1)
    local status=$?
    set -e

    if [[ ${status} -ne 0 ]]; then
        if echo "${output}" | grep -qi "InsufficientInstanceCapacity\|InsufficientCapacity\|capacity"; then
            msg_err "Cannot start instance: No capacity available in this Availability Zone"
            msg_err ""
            msg_err "EC2 instances are permanently bound to their original AZ and cannot be moved."
            msg_err "The AZ where this instance was created currently has no available capacity"
            msg_err "for this instance type."
            msg_err ""
            msg_err "To resolve, destroy and recreate the instance (will find an AZ with capacity):"
            msg_err "  make destroy && make create"
            msg_err ""
            msg_err "Note: This will delete any data on the hypervisor (clusters, images, etc.)"
            exit 1
        fi
        msg_err "Failed to start instance: ${output}"
        exit 1
    fi
}

# Check if the instance exists and get its ID
if [[ ! -f "${SCRIPT_DIR}/../${SHARED_DIR}/aws-instance-id" ]]; then
    echo "Error: No instance found. Please run 'make deploy' first."
    exit 1
fi

INSTANCE_ID=$(cat "${SCRIPT_DIR}/../${SHARED_DIR}/aws-instance-id")
echo "Starting instance ${INSTANCE_ID}..."

# Check current instance state
# shellcheck disable=SC2153 # REGION is sourced from instance.env via common.sh, not a misspelling of local 'region'
INSTANCE_STATE=$(aws --region "${REGION}" ec2 describe-instances --instance-ids "${INSTANCE_ID}" --query 'Reservations[0].Instances[0].State.Name' --output text --no-cli-pager)
echo "Current instance state: ${INSTANCE_STATE}"

case "${INSTANCE_STATE}" in
    "running")
        echo "Instance is already running."
        ;;
    "stopped")
        echo "Starting instance..."
        start_instance_with_capacity_check "${INSTANCE_ID}" "${REGION}"
        echo "Waiting for instance to start..."
        aws --region "${REGION}" ec2 wait instance-running --instance-ids "${INSTANCE_ID}" --no-cli-pager
        echo "Waiting for instance to be ready..."
        aws --region "${REGION}" ec2 wait instance-status-ok --instance-ids "${INSTANCE_ID}" --no-cli-pager
        ;;
    "stopping")
        echo "Instance is currently stopping. Waiting for it to stop completely..."
        aws --region "${REGION}" ec2 wait instance-stopped --instance-ids "${INSTANCE_ID}" --no-cli-pager
        echo "Now starting instance..."
        start_instance_with_capacity_check "${INSTANCE_ID}" "${REGION}"
        echo "Waiting for instance to start..."
        aws --region "${REGION}" ec2 wait instance-running --instance-ids "${INSTANCE_ID}" --no-cli-pager
        echo "Waiting for instance to be ready..."
        aws --region "${REGION}" ec2 wait instance-status-ok --instance-ids "${INSTANCE_ID}" --no-cli-pager
        ;;
    "pending")
        echo "Instance is already starting. Waiting for it to be ready..."
        aws --region "${REGION}" ec2 wait instance-running --instance-ids "${INSTANCE_ID}" --no-cli-pager
        echo "Waiting for instance to be ready..."
        aws --region "${REGION}" ec2 wait instance-status-ok --instance-ids "${INSTANCE_ID}" --no-cli-pager
        ;;
    *)
        echo "Error: Instance is in an unexpected state: ${INSTANCE_STATE}"
        exit 1
        ;;
esac

# Get the current public IP (it may have changed)
HOST_PUBLIC_IP=$(aws --region "${REGION}" ec2 describe-instances --instance-ids "${INSTANCE_ID}" --query 'Reservations[0].Instances[0].PublicIpAddress' --output text --no-cli-pager)
HOST_PRIVATE_IP=$(aws --region "${REGION}" ec2 describe-instances --instance-ids "${INSTANCE_ID}" --query 'Reservations[0].Instances[0].PrivateIpAddress' --output text --no-cli-pager)

echo "${HOST_PUBLIC_IP}" > "${SCRIPT_DIR}/../${SHARED_DIR}/public_address"
echo "${HOST_PRIVATE_IP}" > "${SCRIPT_DIR}/../${SHARED_DIR}/private_address"

echo "Instance ${INSTANCE_ID} is now running."
echo "Public IP: ${HOST_PUBLIC_IP}"
echo "Private IP: ${HOST_PRIVATE_IP}"

# Update SSH config
echo "Updating SSH config for aws-hypervisor..."
(cd "${SCRIPT_DIR}/.." && go run main.go -k aws-hypervisor -h "$HOST_PUBLIC_IP")

# Check and restart the proxy container for immediate proxy capabilities
echo "Checking proxy container status..."
set +e  # Allow commands to fail for proxy container checks
ssh -o ConnectTimeout=10 "$(cat "${SCRIPT_DIR}/../${SHARED_DIR}/ssh_user")@${HOST_PUBLIC_IP}" << 'EOF'
    echo "Checking external-squid proxy container..."
    
    # Check if the container exists and get its status
    CONTAINER_STATUS=$(podman ps -a --filter name=external-squid --format "{{.Status}}" 2>/dev/null || echo "not found")
    
    if [[ "${CONTAINER_STATUS}" == "not found" ]]; then
        echo "Proxy container not found - may not be deployed yet"
    elif [[ "${CONTAINER_STATUS}" =~ ^Up ]]; then
        echo "Proxy container is already running: ${CONTAINER_STATUS}"
    else
        echo "Proxy container exists but not running: ${CONTAINER_STATUS}"
        echo "Attempting to restart proxy container..."
        podman restart external-squid && echo "Proxy container restarted successfully" || echo "Failed to restart proxy container"
    fi
    
    # Give a moment for the container to start
    sleep 5
    
    # Final status check
    FINAL_STATUS=$(podman ps --filter name=external-squid --format "{{.Status}}" 2>/dev/null || echo "not running")
    if [[ "${FINAL_STATUS}" =~ ^Up ]]; then
        echo "Proxy container is now running and ready for use"
    else
        echo "Warning: Proxy container may not be running properly"
    fi
EOF
set -e  # Re-enable exit on error

echo "Instance started successfully!"
echo ""
echo "IMPORTANT: OpenShift cluster recovery options:"
echo ""
echo "If you previously shutdown your cluster:"
echo "  - Start up the cluster: make startup-cluster"
echo ""
echo "If you need to deploy a new cluster:"
echo "  - Clean and redeploy: make redeploy-cluster"
echo "  - For manual deployment: cd ../openshift-clusters && follow README" 
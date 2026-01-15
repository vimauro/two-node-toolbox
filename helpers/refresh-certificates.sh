#!/bin/bash
#
# refresh-certificates.sh - Force renewal of OpenShift API server certificates
#
# This script forces the kube-apiserver-operator to regenerate all short-lived
# signer certificates with fresh 24-hour validity. This is useful before shutting
# down a cluster for an extended period to maximize the certificate validity
# window on the next startup.
#
# Background:
#   OpenShift uses short-lived (24h) intermediate signing certificates that
#   automatically rotate. Leaf certificates (like API server serving certs)
#   are capped by the remaining validity of their signer. If you shut down
#   a cluster when signers are close to expiration, the leaf certs may have
#   very short remaining validity, causing startup failures if the cluster
#   is stopped for too long.
#
# Usage:
#   ./refresh-certificates.sh [--proxy-env /path/to/proxy.env]
#
# If --proxy-env is not specified, the script will look for proxy.env in
# the standard location relative to the two-node-toolbox deploy directory.
#

set -o nounset
set -o pipefail

# Get the directory where this script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Default proxy.env location (relative to helpers/)
DEFAULT_PROXY_ENV="${SCRIPT_DIR}/../deploy/openshift-clusters/proxy.env"

# Parse arguments
PROXY_ENV=""
while [[ $# -gt 0 ]]; do
    case $1 in
        --proxy-env)
            PROXY_ENV="$2"
            shift 2
            ;;
        -h|--help)
            echo "Usage: $0 [--proxy-env /path/to/proxy.env]"
            echo ""
            echo "Force renewal of OpenShift API server certificates to maximize"
            echo "validity window before cluster shutdown."
            echo ""
            echo "Options:"
            echo "  --proxy-env PATH  Path to proxy.env file (default: deploy/openshift-clusters/proxy.env)"
            echo "  -h, --help        Show this help message"
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            echo "Use --help for usage information"
            exit 1
            ;;
    esac
done

# Use default if not specified
if [[ -z "${PROXY_ENV}" ]]; then
    PROXY_ENV="${DEFAULT_PROXY_ENV}"
fi

echo "========================================"
echo "OpenShift Certificate Refresh"
echo "========================================"
echo ""

# Check if proxy.env exists
if [[ ! -f "${PROXY_ENV}" ]]; then
    echo "Error: proxy.env not found at ${PROXY_ENV}"
    echo ""
    echo "Please specify the correct path with --proxy-env or ensure"
    echo "the cluster has been deployed and proxy.env exists."
    exit 1
fi

echo "Loading proxy environment from: ${PROXY_ENV}"
# shellcheck source=/dev/null
source "${PROXY_ENV}"

# Verify we can reach the API
echo "Checking cluster API accessibility..."
if ! oc get nodes --request-timeout=10s &>/dev/null; then
    echo ""
    echo "Error: Cannot reach the cluster API."
    echo ""
    echo "Possible causes:"
    echo "  - Cluster is not running"
    echo "  - Proxy is not accessible"
    echo "  - Certificates have already expired"
    echo ""
    echo "If the cluster is running, check that the proxy (squid) is accessible"
    echo "at ${HTTP_PROXY:-<not set>}"
    exit 1
fi

echo "Cluster API is accessible."
echo ""

# List of short-lived signer secrets to refresh
SIGNERS=(
    "aggregator-client-signer"
    "loadbalancer-serving-signer"
    "localhost-serving-signer"
    "service-network-serving-signer"
)

echo "Forcing renewal of API server signer certificates..."
echo ""

# Helper function to display certificate expiry times
show_cert_expiry() {
    for signer in "${SIGNERS[@]}"; do
        EXPIRY=$(oc get secret "${signer}" -n openshift-kube-apiserver-operator \
            -o jsonpath='{.metadata.annotations.auth\.openshift\.io/certificate-not-after}' 2>/dev/null || echo "not found")
        echo "  ${signer}: ${EXPIRY}"
    done
}

echo "Current certificate expiry times:"
show_cert_expiry
echo ""

# Delete signer secrets to trigger regeneration
echo "Deleting signer secrets to trigger regeneration..."
for signer in "${SIGNERS[@]}"; do
    echo "  Deleting ${signer}..."
    oc delete secret "${signer}" -n openshift-kube-apiserver-operator --ignore-not-found=true
done

echo ""
echo "Waiting for certificate regeneration (up to 60s)..."

# Wait for all secrets to be recreated (active polling instead of fixed sleep)
TIMEOUT=60
ELAPSED=0
while [[ ${ELAPSED} -lt ${TIMEOUT} ]]; do
    ALL_EXIST=true
    for signer in "${SIGNERS[@]}"; do
        if ! oc get secret "${signer}" -n openshift-kube-apiserver-operator &>/dev/null; then
            ALL_EXIST=false
            break
        fi
    done
    if [[ "${ALL_EXIST}" == "true" ]]; then
        break
    fi
    sleep 5
    ELAPSED=$((ELAPSED + 5))
    echo -n "."
done
echo ""
echo ""

echo "New certificate expiry times:"
show_cert_expiry
echo ""

if [[ "${ALL_EXIST}" == "true" ]]; then
    echo "Certificate refresh completed successfully!"
    echo "All signers renewed with fresh 24-hour validity."
else
    echo "Warning: Some certificates may still be regenerating."
    echo "Check kube-apiserver-operator logs if issues persist."
fi

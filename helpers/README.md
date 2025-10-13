# Helpers

Utilities for OpenShift cluster operations including package management and cluster validation.

## Description

This directory contains multiple helper scripts for various OpenShift cluster operations:

- **Resource Agent Patching**: Scripts and playbooks for installing RPM packages on cluster nodes using rpm-ostree's override functionality
- **Fencing Validation**: Tools for validating two-node cluster fencing configuration and health

## Requirements

### For resource-agents-patch.yml (Recommended)
- Ansible
- Inventory file containing OpenShift cluster nodes (see `inventory_ocp_hosts.sample`, or use the automatically generated inventory from `../deploy/openshift-clusters/` - see [Direct VM Access](../deploy/openshift-clusters/README.md#direct-vm-access))
- SSH access configured for `core` user

### For resource-agents-patch.sh
- `oc` CLI tool (logged into OpenShift cluster)
- `jq` for JSON processing
- SSH access to cluster nodes

## Available Scripts

### fencing_validator.sh

Validates fencing configuration and health for two-node OpenShift clusters with STONITH-enabled Pacemaker.

**Features:**
- Non-disruptive validation (default): Checks STONITH presence/enabled status, node health, etcd quorum, and daemon status
- Disruptive testing: Performs actual fencing of both nodes to verify recovery (optional with `--disruptive`)
- Multiple transport methods: Auto-detection, SSH, or oc debug
- IPv4/IPv6 support with automatic node discovery

**Requirements:**
- `oc` CLI tool (logged into OpenShift cluster)
- For SSH transport: passwordless sudo access to cluster nodes
- Two-node cluster with fencing topology

**Usage:**

*From outside the hypervisor (uses oc debug transport by default):*
```bash
# Non-disruptive validation (recommended)
./fencing_validator.sh

# With custom hosts
./fencing_validator.sh --hosts "10.0.0.10,10.0.0.11"
```

*From inside the hypervisor via ansible (requires hypervisor deployed via `make deploy`):*
```bash
# Copy script to hypervisor and execute remotely
ansible all -i deploy/openshift-clusters/inventory.ini -m copy -a "src=helpers/fencing_validator.sh dest=~/fencing_validator.sh mode=0755"
ansible all -i deploy/openshift-clusters/inventory.ini -m shell -a "./fencing_validator.sh"
```

*Disruptive testing options:*
```bash
# Disruptive testing (NOTE: Not yet supported - under development)
./fencing_validator.sh --disruptive

# Dry run to see what would be tested
./fencing_validator.sh --disruptive --dry-run
```

**Note:** Disruptive testing functionality is not yet fully supported and should not be used in production environments.

## Usage

### Build and Patch in One Step (Easiest)

The `build-and-patch-resource-agents.yml` playbook automates the entire workflow:
1. Builds the resource-agents RPM on the hypervisor
2. Copies the RPM back to your laptop
3. Automatically calls `resource-agents-patch.yml` to patch cluster nodes

#### Using Make (Simplest)

```bash
# From the deploy/ directory
make patch-nodes

#### Using Ansible Directly

```bash
# From the helpers/ directory
ansible-playbook -i ../deploy/openshift-clusters/inventory.ini \
  build-and-patch-resource-agents.yml \
  -e rpm_version=4.11
```

**Prerequisites:**
- Inventory file at `../deploy/openshift-clusters/inventory.ini` with both `metal_machine` and `cluster_vms` groups
- SSH access to hypervisor (metal_machine)
- ProxyJump SSH configuration for cluster VMs (automatically configured by setup.yml)

**What it does:**
1. Validates inventory contains both `[metal_machine]` and `[cluster_vms]` groups
2. Installs build dependencies on hypervisor
3. Clones resource-agents repository on hypervisor
4. Builds RPM using `make rpm VERSION=<version>`
5. Fetches RPM back to helpers/ directory
6. Automatically patches cluster_vms group with the new RPM
7. Reboots cluster nodes one at a time with etcd health verification

**Variables:**
- `rpm_version`: Version string for the RPM (default: 4.11)

### Ansible Playbook (Recommended)

The Ansible playbook provides automated installation and rebooting with proper orchestration.

#### Option 1: From Your Laptop

Use with the automatically-generated inventory from the openshift-clusters deployment:

```bash
# Target the cluster_vms group (automatically added by setup.yml playbook)
ansible-playbook -i ../deploy/openshift-clusters/inventory.ini \
  resource-agents-patch.yml \
  -l cluster_vms \
  -e rpm_full_path=/absolute/path/to/package.rpm
```

**Prerequisites:**
- Inventory with `cluster_vms` group (created automatically by update-cluster-inventory.yml task)
- ProxyJump SSH configuration through hypervisor (automatically configured in inventory)
- Absolute path to RPM file on your laptop

**Process:**
1. Validates RPM file exists on localhost
2. Copies RPM to cluster VMs via ProxyJump
3. Installs using rpm-ostree override with privilege escalation
4. Reboots nodes one at a time
5. Verifies etcd health after reboot

#### Option 2: From the Hypervisor

Use with a custom inventory directly on the hypervisor:

```bash
# On the hypervisor, create a simple inventory file first
# See inventory_ocp_hosts.sample for reference
ansible-playbook -i inventory_ocp_hosts \
  resource-agents-patch.yml \
  -e rpm_full_path=/path/to/package.rpm
```

**Prerequisites:**
- Copy RPM file and resource-agents-patch.yml playbook to hypervisor
- Create inventory file listing cluster VM IPs (see `inventory_ocp_hosts.sample`)

**Process:**
1. Validates RPM file existence
2. Copies RPM to all nodes
3. Installs using rpm-ostree override with privilege escalation
4. Reboots nodes one at a time
5. Verifies etcd health after reboot

### resource-agents-patch.sh

Patches OpenShift cluster nodes with RPM packages using rpm-ostree override functionality.

For environments where Ansible is not available:

```bash
./resource-agents-patch.sh /path/to/package.rpm
```

**Process:**
1. Validates required tools and RPM file
2. Discovers all node IPs via OpenShift API
3. Copies RPM to each node using SCP
4. Installs package with `rpm-ostree override replace`
5. Provides manual reboot commands

**Note:** The shell script does not handle reboots automatically. You must manually reboot nodes after installation. Follow the instructions provided at the end of the script execution

## Notes

- Both tools use `rpm-ostree override replace` which is appropriate for updating existing packages
- Node reboots are required to activate rpm-ostree changes
- The Ansible playbooks handle rebooting automatically with proper orchestration; the shell script requires manual intervention
- Plan reboots carefully to maintain cluster availability
- Monitor cluster health during the patching process 
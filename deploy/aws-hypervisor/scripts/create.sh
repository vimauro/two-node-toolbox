#!/bin/bash

SCRIPT_DIR=$(dirname "$0")
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/common.sh"

set -o nounset
set -o errexit
set -o pipefail

#Save stacks events and cleanup capacity reservation on failure
trap 'save_stack_events; cleanup_capacity_on_error' EXIT TERM INT

# Cleanup function for capacity reservation on error
function cleanup_capacity_on_error() {
    set +o errexit
    local reservation_file="${SCRIPT_DIR}/../${SHARED_DIR}/capacity-reservation-id"
    # Only cleanup if stack creation didn't complete successfully
    if [[ -f "${reservation_file}" && ! -f "${SCRIPT_DIR}/../${SHARED_DIR}/.stack-created" ]]; then
        local reservation_id
        reservation_id=$(cat "${reservation_file}")
        cancel_capacity_reservation "${reservation_id}" "${REGION}"
        rm -f "${reservation_file}"
        rm -f "${SCRIPT_DIR}/../${SHARED_DIR}/availability-zone"
    fi
    set -o errexit
}

mkdir -p "${SCRIPT_DIR}/../${SHARED_DIR}"

cf_tpl_file="${SCRIPT_DIR}/../${SHARED_DIR}/${STACK_NAME}-cf-tpl.yaml"

function save_stack_events()
{
  set +o errexit
  aws --region "${REGION}" cloudformation describe-stack-events --stack-name "${STACK_NAME}" --output json > "${SCRIPT_DIR}/../${SHARED_DIR}/stack-events-${STACK_NAME}.json"
  set -o errexit
}

if [[ -n "${RHEL_HOST_AMI}" && -n "${RHEL_VERSION}" ]]; then
    echo "Warning: Both RHEL_HOST_AMI and RHEL_VERSION are set"
    echo "⌊ Choosing RHEL_HOST_AMI=$RHEL_HOST_AMI"
fi

if [[ -z "${RHEL_HOST_AMI}" ]]; then
    RHEL_HOST_AMI=$(get_rhel_ami)
fi

if [[ -z "${RHEL_HOST_AMI}" ]]; then
  echo "must supply an AMI to use for EC2 Instance"
  exit 1
fi

echo "ec2-user" > "${SCRIPT_DIR}/../${SHARED_DIR}/ssh_user"

echo -e "AMI ID: $RHEL_HOST_AMI"
echo -e "Machine Type: $EC2_INSTANCE_TYPE"

# Create capacity reservation to validate and guarantee instance availability
CAPACITY_RESERVATION_ID=""
AVAILABILITY_ZONE=""

if [[ "${ENABLE_CAPACITY_RESERVATION}" == "true" ]]; then
    if reservation_result=$(create_capacity_reservation "${EC2_INSTANCE_TYPE}" "${REGION}"); then
        CAPACITY_RESERVATION_ID=$(echo "${reservation_result}" | awk '{print $1}')
        AVAILABILITY_ZONE=$(echo "${reservation_result}" | awk '{print $2}')

        # Store for cleanup
        echo "${CAPACITY_RESERVATION_ID}" > "${SCRIPT_DIR}/../${SHARED_DIR}/capacity-reservation-id"
        echo "${AVAILABILITY_ZONE}" > "${SCRIPT_DIR}/../${SHARED_DIR}/availability-zone"

        msg_info "Capacity guaranteed in ${AVAILABILITY_ZONE}"
    else
        msg_err "Failed to reserve capacity. Aborting deployment."
        exit 1
    fi
else
    msg_info "Capacity reservation disabled, skipping pre-flight check"
fi

ec2Type="VirtualMachine"
if [[ "$EC2_INSTANCE_TYPE" =~ c[0-9]+[gn].metal ]]; then
  ec2Type="MetalMachine"
fi

# shellcheck disable=SC2154
cat > "${cf_tpl_file}" << EOF
AWSTemplateFormatVersion: 2010-09-09
Description: Template for RHEL machine Launch
Conditions:
# If IsMetal parameter == metal, then do not add a secondary volume
  AddSecondaryVolume: !Not [!Equals [!Ref EC2Type, 'MetalMachine']]
  UseCapacityReservation: !Not [!Equals [!Ref CapacityReservationId, '']]
  UseSpecificAZ: !Not [!Equals [!Ref AvailabilityZone, '']]
Mappings:
 VolumeSize:
   MetalMachine:
     PrimaryVolumeSize: "300"
     SecondaryVolumeSize: "0"
   VirtualMachine:
     PrimaryVolumeSize: "200"
     SecondaryVolumeSize: "100"
Parameters:
  EC2Type: 
    Default: 'VirtualMachine'
    Type: String
  VpcCidr:
    AllowedPattern: ^(([0-9]|[1-9][0-9]|1[0-9]{2}|2[0-4][0-9]|25[0-5])\.){3}([0-9]|[1-9][0-9]|1[0-9]{2}|2[0-4][0-9]|25[0-5])(\/(1[6-9]|2[0-4]))$
    ConstraintDescription: CIDR block parameter must be in the form x.x.x.x/16-24.
    Default: 10.192.0.0/16
    Description: CIDR block for VPC.
    Type: String
  PublicSubnetCidr:
    Description: Please enter the IP range (CIDR notation) for the public subnet in the first Availability Zone
    Type: String
    Default: 10.192.10.0/24
  AmiId:
    Description: Current RHEL AMI to use.
    Type: AWS::EC2::Image::Id
  Machinename:
    MaxLength: 27
    MinLength: 1
    ConstraintDescription: Machinename
    Description: Machinename
    Type: String
    Default: rhel-testbed-ec2-instance
  HostInstanceType:
    Default: t2.medium
    Type: String
  PublicKeyString:
    Type: String
    Description: The public key used to connect to the EC2 instance
  CapacityReservationId:
    Type: String
    Description: EC2 Capacity Reservation ID (optional)
    Default: ""
  AvailabilityZone:
    Type: String
    Description: Specific AZ for instance placement (optional)
    Default: ""

Metadata:
  AWS::CloudFormation::Interface:
    ParameterGroups:
    - Label:
        default: "Host Information"
      Parameters:
      - HostInstanceType
    - Label:
        default: "Network Configuration"
      Parameters:
      - PublicSubnet
    ParameterLabels:
      PublicSubnet:
        default: "Worker Subnet"
      HostInstanceType:
        default: "Worker Instance Type"

Resources:
## VPC Creation

  RHELVPC:
    Type: AWS::EC2::VPC
    Properties:
      CidrBlock: !Ref VpcCidr
      Tags:
        - Key: Name
          Value: RHELVPC

## Setup internet access

  RHELInternetGateway:
    Type: AWS::EC2::InternetGateway
    DeletionPolicy: Delete
    Properties:
      Tags:
        - Key: Name
          Value: RHELInternetGateway

  RHELGatewayAttachment:
    Type: AWS::EC2::VPCGatewayAttachment
    DeletionPolicy: Delete
    Properties:
      VpcId: !Ref RHELVPC
      InternetGatewayId: !Ref RHELInternetGateway

  RHELPublicSubnet:
    Type: AWS::EC2::Subnet
    DeletionPolicy: Delete
    Properties:
      VpcId: !Ref RHELVPC
      CidrBlock: !Ref PublicSubnetCidr
      MapPublicIpOnLaunch: true
      AvailabilityZone: !If [UseSpecificAZ, !Ref AvailabilityZone, !Ref 'AWS::NoValue']
      Tags:
        - Key: Name
          Value: RHELPublicSubnet

  RHELNatGatewayEIP:
    Type: AWS::EC2::EIP
    DeletionPolicy: Delete
    DependsOn: RHELGatewayAttachment
    Properties:
      Domain: vpc

  RHELNatGateway:
    Type: AWS::EC2::NatGateway
    DeletionPolicy: Delete
    DependsOn: RHELNatGatewayEIP
    Properties:
      AllocationId: !GetAtt RHELNatGatewayEIP.AllocationId
      SubnetId: !Ref RHELPublicSubnet

  RHELRouteTable:
    Type: AWS::EC2::RouteTable
    DeletionPolicy: Delete
    Properties:
      VpcId: !Ref RHELVPC
      Tags:
        - Key: Name
          Value: RHELRouteTable

  RHELPublicRoute:
    Type: AWS::EC2::Route
    DependsOn: RHELGatewayAttachment
    Properties:
      RouteTableId: !Ref RHELRouteTable
      DestinationCidrBlock: "0.0.0.0/0"
      GatewayId: !Ref RHELInternetGateway

  RHELPublicSubnetRouteTableAssociation:
    Type: AWS::EC2::SubnetRouteTableAssociation
    DependsOn: RHELRouteTable
    Properties:
      RouteTableId: !Ref RHELRouteTable
      SubnetId: !Ref RHELPublicSubnet

# Setup EC2 Roles and security

  RHELIamRole:
    Type: AWS::IAM::Role
    DeletionPolicy: Delete
    Properties:
      AssumeRolePolicyDocument:
        Version: "2012-10-17"
        Statement:
        - Effect: "Allow"
          Principal:
            Service:
            - "ec2.amazonaws.com"
          Action:
          - "sts:AssumeRole"
      Path: "/"

  RHELInstanceProfile:
    Type: "AWS::IAM::InstanceProfile"
    Properties:
      Path: "/"
      Roles:
      - Ref: "RHELIamRole"

  RHELSecurityGroup:
    Type: AWS::EC2::SecurityGroup
    Properties:
      GroupDescription: RHEL Host Security Group
      SecurityGroupIngress:
      - IpProtocol: icmp
        FromPort: -1
        ToPort: -1
        CidrIp: 0.0.0.0/0
      - IpProtocol: tcp
        FromPort: 22
        ToPort: 22
        CidrIp: 0.0.0.0/0
      - IpProtocol: tcp
        FromPort: 5678
        ToPort: 5678
        CidrIp: 0.0.0.0/0
      - IpProtocol: tcp
        FromPort: 80
        ToPort: 80
        CidrIp: 0.0.0.0/0
      - IpProtocol: tcp
        FromPort: 443
        ToPort: 443
        CidrIp: 0.0.0.0/0
      - IpProtocol: tcp
        FromPort: 8080
        ToPort: 8080
        CidrIp: 0.0.0.0/0
      - IpProtocol: tcp
        FromPort: 9090
        ToPort: 9090
        CidrIp: 0.0.0.0/0
      - IpProtocol: tcp
        FromPort: 5353
        ToPort: 5353
        CidrIp: 0.0.0.0/0
      - IpProtocol: tcp
        FromPort: 6443
        ToPort: 6443
        CidrIp: 0.0.0.0/0
      - IpProtocol: tcp
        FromPort: 8213
        ToPort: 8213
        CidrIp: 0.0.0.0/0
      - IpProtocol: tcp
        FromPort: 30000
        ToPort: 32767
        CidrIp: 0.0.0.0/0
      - IpProtocol: udp
        FromPort: 30000
        ToPort: 32767
        CidrIp: 0.0.0.0/0
      VpcId: !Ref RHELVPC

  RHELInstance:
    Type: AWS::EC2::Instance
    DeletionPolicy: Delete
    DependsOn:
      - RHELPublicSubnet
      - RHELGatewayAttachment
      - RHELInstanceProfile
    Properties:
      ImageId: !Ref AmiId
      IamInstanceProfile: !Ref RHELInstanceProfile
      InstanceType: !Ref HostInstanceType
      CapacityReservationSpecification: !If
        - UseCapacityReservation
        - CapacityReservationTarget:
            CapacityReservationId: !Ref CapacityReservationId
        - !Ref AWS::NoValue
      NetworkInterfaces:
      - AssociatePublicIpAddress: "False"
        DeviceIndex: "0"
        GroupSet:
        - !GetAtt RHELSecurityGroup.GroupId
        SubnetId: !Ref RHELPublicSubnet
      Tags:
      - Key: Name
        Value: !Join ["", [!Ref Machinename]]
      BlockDeviceMappings:
      - DeviceName: /dev/sda1
        Ebs:
          VolumeSize: !FindInMap [VolumeSize, !Ref EC2Type, PrimaryVolumeSize]
          VolumeType: gp3
          Iops: 16000
      - !If
        - AddSecondaryVolume
        - DeviceName: /dev/sdc
          Ebs:
            VolumeSize: !FindInMap [VolumeSize, !Ref EC2Type, SecondaryVolumeSize]
            VolumeType: gp3
            Iops: 16000
        - !Ref AWS::NoValue
      UserData:
        Fn::Base64: !Sub |
          #!/bin/bash -xe

          log_output_file=/tmp/init_output.txt

          echo "====== Authorizing public key ======" | tee -a "\$log_output_file"
          echo "\${PublicKeyString}" >> /home/ec2-user/.ssh/authorized_keys

          sudo dnf install -y git make cockpit lvm2 jq |& tee -a "\$log_output_file"
          sudo systemctl enable --now cockpit.socket |& tee -a "\$log_output_file"

          echo "====== Getting Disk Path ======" | tee -a "\$log_output_file"
          pv_location=\$(sudo lsblk -Jd | jq -r '.blockdevices[] | select(.size == "200G") | "/dev/\(.name)"')
          echo "discovered pv location of (\$pv_location)" | tee -a "\$log_output_file"

          # NOTE: wrappig script vars with {} since the cloudformation will see
          # them as cloudformation vars instead.
          echo "====== Creating PV ======" | tee -a "\$log_output_file"
          sudo pvcreate "\$pv_location" |& tee -a "\$log_output_file"

          echo "====== Creating VG ======" | tee -a "\$log_output_file"
          sudo vgcreate rhel "\$pv_location" |& tee -a "\$log_output_file"

  RHELElasticIP:
    Type: AWS::EC2::EIP
    Properties:
      Domain: vpc
      Tags:
        - Key: Name
          Value: !Ref Machinename

  RHELEIPAssociation:
    Type: AWS::EC2::EIPAssociation
    Properties:
      InstanceId: !Ref RHELInstance
      AllocationId: !GetAtt RHELElasticIP.AllocationId
          
Outputs:
  InstanceId:
    Description: RHEL Host Instance ID
    Value: !Ref RHELInstance
  PrivateIp:
    Description: The bastion host Private DNS, will be used for cluster install pulling release image
    Value: !GetAtt RHELInstance.PrivateIp
  PublicIp:
    Description: The bastion host Public IP, will be used for registering minIO server DNS
    Value: !GetAtt RHELInstance.PublicIp
EOF


echo -e "==== Start to create rhel host ===="
echo "${STACK_NAME}" >> "${SCRIPT_DIR}/../${SHARED_DIR}/to_be_removed_cf_stack_list"
aws --region "$REGION" cloudformation create-stack --stack-name "${STACK_NAME}" \
    --template-body "file://${cf_tpl_file}" \
    --capabilities CAPABILITY_NAMED_IAM \
    --no-cli-pager \
    --parameters \
        "ParameterKey=HostInstanceType,ParameterValue=${EC2_INSTANCE_TYPE}"  \
        "ParameterKey=Machinename,ParameterValue=${STACK_NAME}"  \
        "ParameterKey=AmiId,ParameterValue=${RHEL_HOST_AMI}" \
        "ParameterKey=EC2Type,ParameterValue=${ec2Type}" \
        "ParameterKey=PublicKeyString,ParameterValue=$(cat "${SSH_PUBLIC_KEY}")" \
        "ParameterKey=CapacityReservationId,ParameterValue=${CAPACITY_RESERVATION_ID}" \
        "ParameterKey=AvailabilityZone,ParameterValue=${AVAILABILITY_ZONE}"

echo "Created stack"

echo "Waiting for stack"
aws --region "${REGION}" cloudformation wait stack-create-complete --stack-name "${STACK_NAME}"

echo "$STACK_NAME" > "${SCRIPT_DIR}/../${SHARED_DIR}/rhel_host_stack_name"
# shellcheck disable=SC2016
INSTANCE_ID="$(aws --region "${REGION}" cloudformation describe-stacks --stack-name "${STACK_NAME}" \
--query 'Stacks[].Outputs[?OutputKey == `InstanceId`].OutputValue' --output text)"
echo "Instance ${INSTANCE_ID}"
echo "${INSTANCE_ID}" > "${SCRIPT_DIR}/../${SHARED_DIR}/aws-instance-id"
# shellcheck disable=SC2016
HOST_PUBLIC_IP="$(aws --region "${REGION}" cloudformation describe-stacks --stack-name "${STACK_NAME}" \
  --query 'Stacks[].Outputs[?OutputKey == `PublicIp`].OutputValue' --output text)"
# shellcheck disable=SC2016
HOST_PRIVATE_IP="$(aws --region "${REGION}" cloudformation describe-stacks --stack-name "${STACK_NAME}" \
  --query 'Stacks[].Outputs[?OutputKey == `PrivateIp`].OutputValue' --output text)"

echo "${HOST_PUBLIC_IP}" > "${SCRIPT_DIR}/../${SHARED_DIR}/public_address"
echo "${HOST_PRIVATE_IP}" > "${SCRIPT_DIR}/../${SHARED_DIR}/private_address"

echo "Waiting up to 10 mins for RHEL host to be up."
timeout 10m aws ec2 wait instance-status-ok --instance-id "${INSTANCE_ID}" --no-cli-pager

sleep 15

# Add the host key to known_hosts to avoid prompts while maintaining security
echo "Adding host key for $HOST_PUBLIC_IP to known_hosts..."
ssh-keyscan -H "$HOST_PUBLIC_IP" >> ~/.ssh/known_hosts 2>/dev/null

echo "updating sshconfig for aws-hypervisor"
(cd "${SCRIPT_DIR}/.." && go run main.go -k aws-hypervisor -h "$HOST_PUBLIC_IP")

copy_configure_script
set_aws_machine_hostname

scp "$(cat "${SCRIPT_DIR}/../${SHARED_DIR}/ssh_user")@${HOST_PUBLIC_IP}:/tmp/init_output.txt" "${SCRIPT_DIR}/../${SHARED_DIR}/init_output.txt"

# Mark stack creation as successful (prevents capacity cleanup on exit)
touch "${SCRIPT_DIR}/../${SHARED_DIR}/.stack-created"
msg_info "Instance creation completed successfully"

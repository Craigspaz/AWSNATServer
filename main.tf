
provider "aws" {
  region = "us-east-1"
}

# This is a role which will be assigned to both instances in this code. This role will allow both instances to connect to AWS SSM. This is not necessary for NAT to work properly. This is just to make working on both servers easier
resource "aws_iam_role" "example_ssm_role" {
  name = "example_ssm_role"

  assume_role_policy = <<EOF
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Principal": {
                "Service": "ec2.amazonaws.com"
            },
            "Action": "sts:AssumeRole"
        }
    ]
}
    EOF
}

# This is the built in policy from AWS which gives most of the permissions we need to connect the instance with AWS SSM
data "aws_iam_policy" "amazon_ssm_managed_instance_core" {
    name = "AmazonSSMManagedInstanceCore"
}

# This attaches the policy above to the role
resource "aws_iam_role_policy_attachment" "amazon_ssm_managed_instance_core_attachment" {
    role = aws_iam_role.example_ssm_role.name
    policy_arn = data.aws_iam_policy.amazon_ssm_managed_instance_core.arn
}

# This makes a new policy for doing DescribeInstances *. If you do not have this permission but you do have the AmazonSSMManagedInstanceCore policy you will see the server in SSM but you can't connect to it via SSM
resource "aws_iam_role_policy" "describe_instances" {
    name = "DescribeInstances"
    role = aws_iam_role.example_ssm_role.id
    policy =<<EOF
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Action": "ec2:DescribeInstances",
            "Resource": "*"
        }
    ]
}
    EOF
}

# This creates an instance profile from the role so we can attach it to the servers
resource "aws_iam_instance_profile" "example_ssm_role_profile" {
  name = "example_ssm_role"
  role = aws_iam_role.example_ssm_role.name
}

# This creates a new vpc so we don't have to worry about existing resources
resource "aws_vpc" "example_vpc" {
  cidr_block = "192.168.0.0/16"
  tags = {
    Name = "ExampleVPC"
  }
}

# This is the public subnet and where one of the network interfaces of the NAT Server will live
resource "aws_subnet" "example_public_subnet" {
  vpc_id            = aws_vpc.example_vpc.id
  cidr_block        = "192.168.1.0/24"
  availability_zone = "us-east-1a"
  tags = {
    Name = "Example Public Subnet"
  }
}

# This is the private subnet where the second instance on the NAT Server will live.
resource "aws_subnet" "example_private_subnet" {
  vpc_id            = aws_vpc.example_vpc.id
  cidr_block        = "192.168.2.0/24"
  availability_zone = "us-east-1a"
  tags = {
    Name = "Example Private Subnet"
  }
}

# This is the IGW for the VPC
resource "aws_internet_gateway" "example_igw" {
  vpc_id = aws_vpc.example_vpc.id
}

# This is the public subnet's route table. It has a rule to send all traffic to the IGW
resource "aws_route_table" "example_public_route_table" {
  vpc_id = aws_vpc.example_vpc.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.example_igw.id
  }
}

# This associates teh public route table with the public subnet
resource "aws_route_table_association" "example_public_route_table_association" {
  subnet_id      = aws_subnet.example_public_subnet.id
  route_table_id = aws_route_table.example_public_route_table.id
}

# This is the private subnet route table. It has a rule to send all trafic to the network interface of the NAT Server that is in the private subnet.
resource "aws_route_table" "example_private_route_table" {
  vpc_id = aws_vpc.example_vpc.id

  route {
    cidr_block           = "0.0.0.0/0"
    network_interface_id = aws_network_interface.nat_device_internal_nic.id
  }
}

# This associates the private subnet route table with the subnet
resource "aws_route_table_association" "example_private_route_table_association" {
  subnet_id      = aws_subnet.example_private_subnet.id
  route_table_id = aws_route_table.example_private_route_table.id
}

# This is the security group for the external interface of the NAT Server. It only needs to have outboud traffic out. It does not need to allow any traffic in
resource "aws_security_group" "external_nat_device_sg" {
  name        = "external_nat_sg"
  description = "Blocks all inbound traffic"
  vpc_id      = aws_vpc.example_vpc.id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# This is the security group for the internal interface of the NAT Server
resource "aws_security_group" "internal_nat_device_sg" {
  name        = "internal_nat_sg"
  description = "Allows access to the internet"
  vpc_id      = aws_vpc.example_vpc.id
  ingress { # We need an inbound rule to allow traffic from the private subnet to talk to the network interface otherwise our Test Server will not be able to talk to the NAT Server
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["192.168.2.0/24"]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# This creates the internal network interface for the NAT Server
resource "aws_network_interface" "nat_device_internal_nic" {
  subnet_id         = aws_subnet.example_private_subnet.id
  security_groups   = [aws_security_group.internal_nat_device_sg.id]
  source_dest_check = false # We need to disable source destination checks since the traffic coming to it will not always be for the NAT Server and the server should just forward it
  attachment {
    instance     = aws_instance.nat_device.id
    device_index = 1
  }
}

# This is the NAT Server
resource "aws_instance" "nat_device" {
  ami                         = "ami-0ed9277fb7eb570c9"
  instance_type               = "t3a.nano"
  vpc_security_group_ids      = [aws_security_group.external_nat_device_sg.id]
  subnet_id                   = aws_subnet.example_public_subnet.id
  associate_public_ip_address = true # We want the server to have a public IP so it can talk to the internet gateway
  iam_instance_profile        = aws_iam_instance_profile.example_ssm_role_profile.id
  source_dest_check           = false # We need source destination checks disabled for the default network interface for the server so it can forward traffic
  tags = {
    Name = "NAT Server"
  }

# This is the script which configures NAT
  user_data = <<EOF
#!/bin/bash
sudo su -
yum update -y
yum install iptables-services iptables-utils -y
systemctl enable iptables
systemctl start iptables
iptables -t nat -nvL
iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE
iptables-save
service iptables save
iptables -I FORWARD 1 -i eth0 -o eth1 -m state --state RELATED,ESTABLISHED -j ACCEPT
iptables -I FORWARD 2 -i eth1 -o eth0 -j ACCEPT
iptables-save
service iptables save
systemctl restart iptables
echo "net.ipv4.ip_forward = 1" > /etc/sysctl.d/99-sysctl.conf
sysctl -p
reboot
EOF
}

# This is the test Server
resource "aws_instance" "test_server" {
  ami                    = "ami-0ed9277fb7eb570c9"
  instance_type          = "t3a.nano"
  vpc_security_group_ids = [aws_security_group.external_nat_device_sg.id]
  subnet_id              = aws_subnet.example_private_subnet.id
  iam_instance_profile   = aws_iam_instance_profile.example_ssm_role_profile.id
  tags = {
    Name = "Test Server"
  }
  user_data = <<EOF
#!/bin/bash
sudo su -
sleep 1m
yum update -y
EOF
}

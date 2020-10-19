#################################
# Cloud Provider details: AWS
#################################
provider "aws" {
  profile     = "default"
  region      = var.region
}

#################################
# Create outside firewall subnets
#################################
resource "aws_subnet" "outside" {
  vpc_id                  = var.vpcid
  cidr_block              = var.outsubnet
  availability_zone       = var.azone
  map_public_ip_on_launch = true
  tags = {
    Name = "Outside"
  }
}

#################################
# Create inside firewall subnets
#################################
resource "aws_subnet" "inside" {
  vpc_id                  = var.vpcid
  cidr_block              = var.insubnet
  availability_zone       = var.azone
  map_public_ip_on_launch = false
  tags = {
    Name = "Inside"
  }
}

####################################
# Create management firewall subnets
####################################
resource "aws_subnet" "management" {
  vpc_id                  = var.vpcid
  cidr_block              = var.mgmtsubnet
  availability_zone       = var.azone
  map_public_ip_on_launch = true
  tags = {
    Name = "Management"
  }
}

######################################################################
# Create an internet gateway to give our subnet access to the internet
######################################################################
resource "aws_internet_gateway" "default" {
  vpc_id = var.vpcid
  tags = {
    Name = "fwIGW"
  }
}

#############################
# Create firewall route table
#############################
resource "aws_route_table" "firewall_rt" {
  vpc_id = var.vpcid
  tags = {
    Name = "firewallRT"
  }
}

#######################
# Create default route
#######################
resource "aws_route" "defaultroute" {
  route_table_id         = aws_route_table.firewall_rt.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.default.id
}

##########################################################################################
# Associate three firewall subnets(management, inside, outside) with firewall route table
##########################################################################################
resource "aws_route_table_association" "firewallrt_subnet1" {
  subnet_id      = aws_subnet.outside.id
  route_table_id = aws_route_table.firewall_rt.id
}
resource "aws_route_table_association" "firewallrt_subnet2" {
  subnet_id      = aws_subnet.inside.id
  route_table_id = aws_route_table.firewall_rt.id
}
resource "aws_route_table_association" "firewallrt_subnet3" {
  subnet_id      = aws_subnet.management.id
  route_table_id = aws_route_table.firewall_rt.id
}

#################################################################
# Security group for firewall data interfaces(inside and outside)
#################################################################
resource "aws_security_group" "firewallSG" {
  name        = "firewallSG"
  description = "SG for firewalls"
  vpc_id      = var.vpcid

  # Health check access from outside LB
  ingress {
    from_port   = 6612
    to_port     = 6612
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # outbound internet access
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = {
    Name = "firewallSG"
  }
}

###################################################
# Security group for firewall management interfaces
###################################################
resource "aws_security_group" "mgmtSG" {
  name        = "managementSG"
  description = "SG for management"
  vpc_id      = var.vpcid

  # SSH access from anywhere
  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  ingress {
    from_port   = -1
    to_port     = -1
    protocol    = "icmp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  # outbound internet access
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = {
    Name = "managementSG"
  }
}

############################################################
# Creating management interfaces(with EIP) for FTDv instance
############################################################
resource "aws_network_interface" "management" {
  count               = var.instance_count
  subnet_id           = aws_subnet.management.id
  security_groups     = [aws_security_group.mgmtSG.id]
  source_dest_check   = false
  tags = {
    Name = "FirepowerManagement"
  }
}
resource "aws_eip" "managementip" {
  count                     = var.instance_count
  vpc                       = true
  network_interface         = aws_network_interface.management[count.index].id
  tags = {
    Name = "FirepowerManagementEIP"
  }
}

##################################################
# Creating diagnostic interfaces for FTDv instance
##################################################
resource "aws_network_interface" "diagnostic" {
  count           = var.instance_count
  subnet_id       = aws_subnet.management.id
  security_groups = [aws_security_group.mgmtSG.id]
  source_dest_check   = false
  tags = {
    Name = "FirepowerDiagnostic"
  }
}

###########################################################
# Creating outside interfaces (with EIP) for FTDv instance
###########################################################
resource "aws_network_interface" "outside" {
  count           = var.instance_count
  subnet_id       = aws_subnet.outside.id
  security_groups = [aws_security_group.firewallSG.id]
  source_dest_check   = false

  attachment {
    instance     = aws_instance.ftdv[count.index].id
    device_index = 2
  }
  tags = {
    Name = "FirepowerOutside"
  }
}
resource "aws_eip" "outsideeip" {
  count                     = var.instance_count
  vpc                       = true
  network_interface         = aws_network_interface.outside[count.index].id
  tags = {
    Name = "FirepowerOutsideEIP"
  }
}

##############################################
# Creating inside interfaces for FTDv instance
##############################################
resource "aws_network_interface" "inside" {
  count           = var.instance_count
  subnet_id       = aws_subnet.inside.id
  security_groups = [aws_security_group.firewallSG.id]
  source_dest_check   = false

  attachment {
    instance     = aws_instance.ftdv[count.index].id
    device_index = 3
  }
  tags = {
    Name = "FirepowerInside"
  }
}

################################################
# Deploying FTDv instances (SingleAZ deployment)
################################################
data "template_file" "initial_ftd_config" {
  template = file("config.json")
}

resource "aws_instance" "ftdv" {
  count                  = var.instance_count
  ami                    = var.region_ami[var.region]
  instance_type          = var.instance_type
  key_name               = var.key_name
  monitoring             = true
  user_data              = data.template_file.initial_ftd_config.rendered

  network_interface{
    device_index = 0
    network_interface_id = aws_network_interface.management[count.index].id
  }
  network_interface{
    device_index = 1
    network_interface_id = aws_network_interface.diagnostic[count.index].id
  }

  tags = {
    Name = "FirepowerNGFWv"
  }
}

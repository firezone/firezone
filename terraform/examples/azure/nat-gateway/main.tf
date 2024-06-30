# Change these to match your environment
locals {
  location       = "East US"
  admin_ssh_key  = file("~/.ssh/id_rsa.azure.pub")
  firezone_token = "YOUR_FIREZONE_TOKEN"
}

module "azure_firezone_gateway" {
  source = "github.com/firezone/firezone/terraform/modules/azure/firezone-gateway"

  ###################
  # Required inputs #
  ###################

  # Azure resource group information
  resource_group_location = azurerm_resource_group.firezone.location
  resource_group_name     = azurerm_resource_group.firezone.name

  # Generate a token from the admin portal in Sites -> <site> -> Deploy Gateway.
  # Only one token is needed for the cluster.
  firezone_token = local.firezone_token

  # Attach the Gateways to your subnet.
  private_subnet = azurerm_subnet.private.id

  # Admin SSH public key. Must be RSA.
  admin_ssh_key = local.admin_ssh_key

  # Attach the Gateways to your NSG.
  network_security_group_id = azurerm_network_security_group.firezone.id

  # Attach the NAT Gateway
  nat_gateway_id = azurerm_nat_gateway.firezone.id

  ###################
  # Optional inputs #
  ###################

  # Pick an image to use. Defaults to Ubuntu 22.04 LTS.
  # source_image_reference {
  #   publisher = "Canonical"
  #   offer     = "0001-com-ubuntu-server-jammy"
  #   sku       = "22_04-lts"
  #   version   = "latest"
  # }

  # Deploy a specific version of the Gateway. Generally, we recommend using the latest version.
  # firezone_version    = "latest"

  # Override the default API URL. This should almost never be needed.
  firezone_api_url = "wss://api.firez.one"

  # Gateways are very lightweight. In general it's preferrable to deploy
  # more smaller Gateways than fewer larger Gateways if you need to scale
  # horizontally.
  # See https://www.firezone.dev/kb/deploy/gateways#sizing-recommendations.
  # instance_type       = "Standard_B1ls"

  # We recommend a minimum of 3 instances for high availability.
  # desired_capacity    = 3
}

# Configure the Azure provider
provider "azurerm" {
  features {}
}

# Create a resource group in your preferred region
resource "azurerm_resource_group" "firezone" {
  name     = "firezone-resources"
  location = local.location
}

# Create a virtual network
resource "azurerm_virtual_network" "firezone" {
  name                = "firezone-vnet"
  address_space       = ["172.16.0.0/16"]
  location            = azurerm_resource_group.firezone.location
  resource_group_name = azurerm_resource_group.firezone.name
}

# Create a public subnet
resource "azurerm_subnet" "public" {
  name                 = "firezone-public-subnet"
  resource_group_name  = azurerm_resource_group.firezone.name
  virtual_network_name = azurerm_virtual_network.firezone.name
  address_prefixes     = ["172.16.0.0/24"]
}

# Create a private subnet
resource "azurerm_subnet" "private" {
  name                 = "firezone-private-subnet"
  resource_group_name  = azurerm_resource_group.firezone.name
  virtual_network_name = azurerm_virtual_network.firezone.name
  address_prefixes     = ["172.16.1.0/24"]
}

# Create a public IP for the NAT gateway
resource "azurerm_public_ip" "firezone" {
  name                = "firezone-pip"
  location            = azurerm_resource_group.firezone.location
  resource_group_name = azurerm_resource_group.firezone.name
  allocation_method   = "Static"
  sku                 = "Standard"
}

# OPTIONAL: Create a bastion to allow SSH access to the VMs
resource "azurerm_bastion_host" "firezone" {
  name                = "firezone-bastion"
  location            = azurerm_resource_group.firezone.location
  resource_group_name = azurerm_resource_group.firezone.name
  sku                 = "Standard"
  tunneling_enabled   = true

  ip_configuration {
    name                 = "firezone-bastion-ip"
    subnet_id            = azurerm_subnet.bastion.id
    public_ip_address_id = azurerm_public_ip.firezone-bastion.id
  }
}
resource "azurerm_public_ip" "firezone-bastion" {
  name                = "firezone-bastion-pip"
  location            = azurerm_resource_group.firezone.location
  resource_group_name = azurerm_resource_group.firezone.name
  allocation_method   = "Static"
  sku                 = "Standard"
}
resource "azurerm_subnet" "bastion" {
  name                 = "AzureBastionSubnet"
  resource_group_name  = azurerm_resource_group.firezone.name
  virtual_network_name = azurerm_virtual_network.firezone.name
  address_prefixes     = ["172.16.2.0/24"]
}

# Create a NAT gateway
resource "azurerm_nat_gateway" "firezone" {
  name                = "firezone-nat-gateway"
  location            = azurerm_resource_group.firezone.location
  resource_group_name = azurerm_resource_group.firezone.name
}

# Create a NAT gateway association
resource "azurerm_nat_gateway_public_ip_association" "firezone" {
  nat_gateway_id       = azurerm_nat_gateway.firezone.id
  public_ip_address_id = azurerm_public_ip.firezone.id
}

# Associate the NAT gateway with the public subnet
resource "azurerm_subnet_nat_gateway_association" "public" {
  nat_gateway_id = azurerm_nat_gateway.firezone.id
  subnet_id      = azurerm_subnet.public.id
}

# Associate the NAT gateway with the private subnet
resource "azurerm_subnet_nat_gateway_association" "private" {
  nat_gateway_id = azurerm_nat_gateway.firezone.id
  subnet_id      = azurerm_subnet.private.id
}

# Create a network security group
resource "azurerm_network_security_group" "firezone" {
  name                = "firezone-nsg"
  location            = azurerm_resource_group.firezone.location
  resource_group_name = azurerm_resource_group.firezone.name

  security_rule {
    name                       = "allow-ssh"
    priority                   = 1001
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "22"
    source_address_prefix      = "172.16.0.0/24"
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "allow-all-outbound"
    priority                   = 1002
    direction                  = "Outbound"
    access                     = "Allow"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "0-65535"
    source_address_prefix      = "*"
    destination_address_prefix = "0.0.0.0/0"
  }
}

# Attach the NSG to the public subnet
resource "azurerm_subnet_network_security_group_association" "public" {
  subnet_id                 = azurerm_subnet.public.id
  network_security_group_id = azurerm_network_security_group.firezone.id
}

# Attach the NSG to the private subnet
resource "azurerm_subnet_network_security_group_association" "private" {
  subnet_id                 = azurerm_subnet.private.id
  network_security_group_id = azurerm_network_security_group.firezone.id
}

output "nat_public_ip" {
  description = "The public IP of the NAT gateway"
  value       = azurerm_public_ip.firezone.ip_address
}

output "bastion_public_ip" {
  description = "The public IP of the bastion host"
  value       = azurerm_public_ip.firezone-bastion.ip_address
}

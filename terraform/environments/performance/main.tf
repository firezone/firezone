locals {
  # Find this with `az account subscription list`
  arm_subscription_id = var.subscription_id

  # Generate these by following
  # https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/guides/service_principal_client_secret?ajs_aid=fdab1b75-b67a-4e43-8a41-7cb014d5c881&product_intent=terraform#creating-a-service-principal-using-the-azure-cli
  #
  # and then saving to terraform.tfvars in this directory:
  #
  # arm_client_id = "..."
  # arm_client_secret = "..."
  # arm_tenant_id = "..."
  arm_client_id     = var.arm_client_id
  arm_client_secret = var.arm_client_secret
  arm_tenant_id     = var.arm_tenant_id
}

terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.0.2"
    }
  }

  required_version = ">= 1.1.0"
}

provider "azurerm" {
  features {}
}

# US-west resource group
resource "azurerm_resource_group" "rg-westus2" {
  name     = "${var.naming_prefix}-rg-westus2"
  location = "westus2"
}

# US-west virtual network
resource "azurerm_virtual_network" "vnet-westus2" {
  name                = "${var.naming_prefix}-vnet-westus2"
  resource_group_name = azurerm_resource_group.rg-westus2.name
  location            = azurerm_resource_group.rg-westus2.location
  address_space       = ["10.0.0.0/16"]
}

# US-west subnet
resource "azurerm_subnet" "subnet-westus2" {
  name                 = "${var.naming_prefix}-subnet-westus2"
  resource_group_name  = azurerm_resource_group.rg-westus2.name
  virtual_network_name = azurerm_virtual_network.vnet-westus2.name
  address_prefixes     = ["10.0.0.0/24"]
}

# NIC for US-west VM
resource "azurerm_network_interface" "nic-westus2" {
  name                = "${var.naming_prefix}-nic-westus2"
  location            = azurerm_resource_group.rg-westus2.location
  resource_group_name = azurerm_resource_group.rg-westus2.name

  # Enable accelerated networking, can only be enabled on one NIC per VM
  enable_accelerated_networking = true

  ip_configuration {
    name                          = "${var.naming_prefix}-ipconfig-westus2"
    subnet_id                     = azurerm_subnet.subnet-westus2.id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.publicip-westus2.id
  }
}

# Public IP for US-west VM
resource "azurerm_public_ip" "publicip-westus2" {
  name                = "${var.naming_prefix}-publicip-westus2"
  location            = azurerm_resource_group.rg-westus2.location
  resource_group_name = azurerm_resource_group.rg-westus2.name
  allocation_method   = "Dynamic"
}

# US-west VM
resource "azurerm_linux_virtual_machine" "vm-westus2" {
  name                = "${var.naming_prefix}-vm-westus2"
  resource_group_name = azurerm_resource_group.rg-westus2.name
  location            = azurerm_resource_group.rg-westus2.location

  # 16 vCPUs, 56 GB RAM, Premium SSD
  size = "Standard_DS5_v2"
  network_interface_ids = [
    azurerm_network_interface.nic-westus2.id
  ]

  # Username of the admin user
  admin_username = "adminuser"

  admin_ssh_key {
    username   = "adminuser"
    public_key = var.admin_ssh_pubkey
  }

  # Allow others access to the VM
  identity {
    type = "SystemAssigned"
  }

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "0001-com-ubuntu-server-jammy"
    sku       = "22_04-lts"
    version   = "latest"
  }
}

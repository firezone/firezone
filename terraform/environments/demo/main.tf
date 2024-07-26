# Change these to match your environment
locals {
  unique_id         = uuid()
  location          = "East US"
  admin_username    = "firezone"
  admin_ssh_key     = file("~/.ssh/id_rsa.azure.pub")
  postgres_password = var.postgres_password
  firezone_token    = var.token
  # metabase_user     = "demo"
  # metabase_password = var.metabase_password
}

module "gateway" {
  source = "firezone/gateway/azurerm"

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

  # Admin SSH username.
  admin_username = local.admin_username

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

  # Gateways are very lightweight. In general it's preferable to deploy
  # more smaller Gateways than fewer larger Gateways if you need to scale
  # horizontally.
  # See https://www.firezone.dev/kb/deploy/gateways#sizing-recommendations.
  # instance_type       = "Standard_B1ls"

  # We recommend a minimum of 3 instances for high availability.
  desired_capacity = 10
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

# OPTIONAL: Create a bastion to allow SSH access to the VMs which
# can be helpful for debugging when setting up the Gateways.
# After you're sure this configuration works, you can remove the bastion.
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
    name                       = "allow-mb"
    priority                   = 1003
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "3000"
    source_address_prefix      = "172.16.1.0/24"
    destination_address_prefix = "172.16.1.0/24"
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

# Postgres instance for metabase demo
resource "azurerm_postgresql_server" "firezone" {
  name                = "firezone-postgres-${local.unique_id}"
  location            = azurerm_resource_group.firezone.location
  resource_group_name = azurerm_resource_group.firezone.name

  sku_name = "B_Gen5_2"

  storage_mb                   = 5120
  backup_retention_days        = 7
  geo_redundant_backup_enabled = false
  auto_grow_enabled            = true

  administrator_login          = "postgres"
  administrator_login_password = local.postgres_password
  version                      = "11"
  ssl_enforcement_enabled      = true
}
resource "azurerm_postgresql_database" "firezone" {
  name                = "metabase-db-${local.unique_id}"
  resource_group_name = azurerm_resource_group.firezone.name
  server_name         = azurerm_postgresql_server.firezone.name
  charset             = "UTF8"
  collation           = "English_United States.1252"

  # prevent the possibility of accidental data loss
  # not needed for demo
  # lifecycle {
  #   prevent_destroy = true
  # }
}

# Metabase subnet
# resource "azurerm_subnet" "metabase" {
#   name                 = "firezone-metabase-subnet"
#   resource_group_name  = azurerm_resource_group.firezone.name
#   virtual_network_name = azurerm_virtual_network.firezone.name
#   address_prefixes     = ["172.16.3.0/24"]

#   delegation {
#     name = "firezone-delegation"

#     service_delegation {
#       name    = "Microsoft.Web/serverFarms"
#       actions = ["Microsoft.Network/virtualNetworks/subnets/action"]
#     }
#   }
# }

# Associate the NAT gateway with the metabase subnet
# resource "azurerm_subnet_nat_gateway_association" "metabase" {
#   nat_gateway_id = azurerm_nat_gateway.firezone.id
#   subnet_id      = azurerm_subnet.metabase.id
# }

# resource "azurerm_subnet_network_security_group_association" "metabase-private" {
#   subnet_id                 = azurerm_subnet.metabase.id
#   network_security_group_id = azurerm_network_security_group.metabase.id
# }

# resource "azurerm_network_security_group" "metabase" {
#   name                = "firezone-metabase-nsg"
#   location            = azurerm_resource_group.firezone.location
#   resource_group_name = azurerm_resource_group.firezone.name

#   security_rule {
#     name                       = "allow-ssh"
#     priority                   = 1001
#     direction                  = "Inbound"
#     access                     = "Allow"
#     protocol                   = "Tcp"
#     source_port_range          = "*"
#     destination_port_range     = "22"
#     source_address_prefix      = "172.16.0.0/16"
#     destination_address_prefix = "*"
#   }

#   security_rule {
#     name                       = "allow-metabase"
#     priority                   = 1002
#     direction                  = "Inbound"
#     access                     = "Allow"
#     protocol                   = "Tcp"
#     source_port_range          = "*"
#     destination_port_range     = "3000"
#     source_address_prefix      = "172.16.0.0/16"
#     destination_address_prefix = "*"
#   }

#   security_rule {
#     name                       = "allow-all-outbound"
#     priority                   = 1002
#     direction                  = "Outbound"
#     access                     = "Allow"
#     protocol                   = "*"
#     source_port_range          = "*"
#     destination_port_range     = "0-65535"
#     source_address_prefix      = "*"
#     destination_address_prefix = "0.0.0.0/0"
#   }
# }


# Metabase app service
# resource "azurerm_service_plan" "metabase" {
#   name                = "metabase-sp-${local.unique_id}"
#   location            = azurerm_resource_group.firezone.location
#   resource_group_name = azurerm_resource_group.firezone.name
#   os_type             = "Linux"
#   sku_name            = "B1"
# }

# resource "azurerm_linux_web_app" "metabase" {
#   name                          = "metabase-app-${local.unique_id}"
#   location                      = azurerm_resource_group.firezone.location
#   resource_group_name           = azurerm_resource_group.firezone.name
#   service_plan_id               = azurerm_service_plan.metabase.id
#   virtual_network_subnet_id     = azurerm_subnet.metabase.id
#   public_network_access_enabled = false

#   site_config {
#     http2_enabled      = true
#     websockets_enabled = true

#     application_stack {
#       docker_image_name   = "metabase/metabase"
#       docker_registry_url = "https://index.docker.io"
#     }
#   }

#   app_settings = {
#     MB_DB_TYPE   = "postgres"
#     MB_DB_DBNAME = azurerm_postgresql_database.metabase.name
#     MB_DB_PORT   = "5432"
#     MB_DB_USER   = azurerm_postgresql_server.metabase.administrator_login
#     MB_DB_PASS   = azurerm_postgresql_server.metabase.administrator_login_password
#     MB_DB_HOST   = azurerm_postgresql_server.metabase.fqdn
#   }
# }

# resource "azurerm_subnet" "endpoint" {
#   name                 = "firezone-endpoint-subnet"
#   resource_group_name  = azurerm_resource_group.firezone.name
#   virtual_network_name = azurerm_virtual_network.firezone.name
#   address_prefixes     = ["172.16.4.0/24"]

#   enforce_private_link_endpoint_network_policies = true
# }

# resource "azurerm_public_ip" "metabase" {
#   name                = "metabase-pip-${local.unique_id}"
#   sku                 = "Standard"
#   location            = azurerm_resource_group.firezone.location
#   resource_group_name = azurerm_resource_group.firezone.name
#   allocation_method   = "Static"
# }

# resource "azurerm_lb" "metabase" {
#   name                = "metabase-lb-${local.unique_id}"
#   sku                 = "Standard"
#   location            = azurerm_resource_group.firezone.location
#   resource_group_name = azurerm_resource_group.firezone.name

#   frontend_ip_configuration {
#     name                 = azurerm_public_ip.metabase.name
#     public_ip_address_id = azurerm_public_ip.metabase.id
#   }
# }

# resource "azurerm_private_link_service" "metabase" {
#   name                = "metabase-pls-${local.unique_id}"
#   location            = azurerm_resource_group.firezone.location
#   resource_group_name = azurerm_resource_group.firezone.name

#   nat_ip_configuration {
#     name      = azurerm_public_ip.metabase.name
#     primary   = true
#     subnet_id = azurerm_subnet.metabase.id
#   }

#   load_balancer_frontend_ip_configuration_ids = [
#     azurerm_lb.metabase.frontend_ip_configuration[0].id,
#   ]
# }

# resource "azurerm_private_endpoint" "metabase" {
#   name                = "metabase-pe-${local.unique_id}"
#   location            = azurerm_resource_group.firezone.location
#   resource_group_name = azurerm_resource_group.firezone.name
#   subnet_id           = azurerm_subnet.endpoint.id

#   private_service_connection {
#     name                           = "metabase-psc-${local.unique_id}"
#     private_connection_resource_id = azurerm_private_link_service.metabase.id
#     is_manual_connection           = false
#   }
# }

output "nat_public_ip" {
  description = "The public IP of the NAT gateway"
  value       = azurerm_public_ip.firezone.ip_address
}

output "bastion_public_ip" {
  description = "The public IP of the bastion host"
  value       = azurerm_public_ip.firezone-bastion.ip_address
}

output "postgres_fqdn" {
  description = "The fully qualified domain name of the Postgres server"
  value       = azurerm_postgresql_server.firezone.fqdn
}

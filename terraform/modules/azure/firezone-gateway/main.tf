resource "azurerm_orchestrated_virtual_machine_scale_set" "firezone" {
  name                        = "firezone-vmss"
  location                    = var.resource_group_location
  resource_group_name         = var.resource_group_name
  sku_name                    = var.instance_type
  instances                   = var.desired_capacity
  platform_fault_domain_count = var.platform_fault_domain_count

  source_image_reference {
    publisher = var.source_image_reference.publisher
    offer     = var.source_image_reference.offer
    sku       = var.source_image_reference.sku
    version   = var.source_image_reference.version
  }

  network_interface {
    name    = "firezone-nic"
    primary = true

    # Required to egress traffic
    enable_ip_forwarding = true

    network_security_group_id = var.network_security_group_id

    ip_configuration {
      name      = "internal"
      primary   = true
      subnet_id = var.private_subnet
    }
  }

  os_profile {
    linux_configuration {
      admin_username = var.admin_username

      admin_ssh_key {
        username   = var.admin_username
        public_key = var.admin_ssh_key
      }
    }

    custom_data = base64encode(<<-EOF
    #!/bin/bash
    set -e

    sudo apt-get update
    sudo apt-get install -y curl uuid-runtime

    FIREZONE_TOKEN="${var.firezone_token}" \
    FIREZONE_VERSION="${var.firezone_version}" \
    FIREZONE_NAME="${var.firezone_name}" \
    FIREZONE_ID="$(uuidgen)" \
    FIREZONE_API_URL="${var.firezone_api_url}" \
    bash <(curl -fsSL https://raw.githubusercontent.com/firezone/firezone/main/scripts/gateway-systemd-install.sh)

    EOF
    )
  }

  tags = var.extra_tags
}

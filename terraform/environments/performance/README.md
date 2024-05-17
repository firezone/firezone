# Performance Terraform environment

This directory contains terraform examples for spinning up VMs on Azure to be
used for performance testing.

This is primarily meant to be used internal by the Firezone Team at this time,
but anyone can use the scripts here by changing the variables in a local
`terraform.tfvars` as needed.

## Get started

1. [Install](https://developer.hashicorp.com/terraform/tutorials/aws-get-started/install-cli)
   Terraform if you haven't already.
1. [Install](https://learn.microsoft.com/en-us/cli/azure/install-azure-cli) the
   Azure CLI if you haven't already.
1. Clone this repository, and `cd` to this directory.
1. Run `terraform init` to initialize the directory.
1. Login to Azure using the Azure CLI with `az login`.
1. Find the subscription ID you want to use with `az account subscription list`.
   If unsure, contact your Azure admin to avoid incurring billing charges under
   the wrong billing subscription.
1. Generate a keypair to use for your own admin SSH access (**must** be RSA):
   ```shell
   ssh-keygen -t rsa -b 4096 -f ~/.ssh/id_rsa.azure
   ```
1. Obtain `terraform.tfvars` using one of the following methods:

   1. Your team's shared credentials vault (e.g. 1password)
   1. Your Azure admin
   1. Or, generate it by following the instructions at
      https://developer.hashicorp.com/terraform/tutorials/azure-get-started/azure-build
      and populating a `terraform.tfvars` file in this directory:

      ```hcl
      # Azure billing subscription ID
      subscription_id = "SUBSCRIPTION-ID-FROM-PREVIOUS-STEP"

      # Obtain these variables by following the guide above
      arm_client_id = "AZURE-SERVICE-PRINCIPAL-CLIENT-ID"
      arm_client_secret = "AZURE-SERVICE-PRINCIPAL-CLIENT-SECRET"
      arm_tenant_id = "AZURE-SERVICE-PRINCIPAL-TENANT-ID"

      # All VMs need a public RSA SSH key specified for the admin user. Insert yours below.
      admin_ssh_public_key = "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQC7..."

      # Set your own naming prefix to avoid clobbering others' resources
      naming_prefix = "CHANGEME"
      ```

1. Run `terraform apply` to create the resources.
1. Done! You can now SSH into your VM like so:
   ```shell
   # Login using the name of resources used in Terraform config above
   az ssh vm \
    --resource-group CHANGEME-rg-westus2 \
    --vm-name CHANGEME-vm-westus2 \
    --private-key-file ~/.ssh/id_rsa.azure \
    --local-user adminuser
   ```

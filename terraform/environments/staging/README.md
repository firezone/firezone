# Staging environment

This directory houses the Firezone staging environment.

## SSH access to the staging Gateway on AWS

1. Create a new AWS Access Key and Secret Key in the AWS IAM console.
1. [Install the aws CLI](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html)
   and authenticate it using the new Access Key and Secret Key.
1. SSH to the Gateway using instance connect:
   ```
   aws ec2-instance-connect ssh --instance-id \
     $(aws ec2 describe-instances --filters "Name=tag:Name,Values=gateway - staging" --query "Reservations[*].Instances[*].InstanceId" --output text) \
     --os-user ubuntu --connection-type eice
   ```

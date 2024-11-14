# Staging environment

This directory houses the Firezone staging environment.

## SSH access to the staging Gateway on AWS

1. [Create a new AWS Access Key and Secret Key in the AWS IAM console.](https://docs.aws.amazon.com/IAM/latest/UserGuide/id_credentials_access-keys.html#Using_CreateAccessKey)
1. [Install the aws CLI](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html)
   and then run `aws configure` to set up your credentials. Choose `us-east-1`
   as the default region.
1. SSH to the Gateway using instance connect:
   ```
   aws ec2-instance-connect ssh --instance-id \
     $(aws ec2 describe-instances --filters "Name=tag:Name,Values=gateway - staging" --query "Reservations[*].Instances[*].InstanceId" --output text) \
     --os-user ubuntu --connection-type eice
   ```

## Set NAT type on AWS NAT gateway VM

Note: The NAT gateway VM will default to using a non-symmetric NAT when deployed or restarted.

### Enable Symmetric NAT

1. SSH in to the NAT gateway VM using the instructions above by replacing `gateway` with `nat`
1. Run the following:
   ```
   sudo iptables -t nat -F && sudo iptables -t nat -A POSTROUTING -o ens5 -j MASQUERADE --random
   ```

### Enable Non-Symmetric NAT

1. SSH in to the NAT gateway VM using the instructions above by replacing `gateway` with `nat`
1. Run the following:
   ```
   sudo iptables -t nat -F && sudo iptables -t nat -A POSTROUTING -o ens5 -j MASQUERADE
   ```

FIREZONE_DEV='172.28.0.0/16'
TABLE=333444

sudo ip -4 rule del from $FIREZONE_DEV table $TABLE
sudo ip -4 route flush table $TABLE

FIREZONE_DEV='172.28.0.0/16'
TABLE=333444
DEFAULT_ROUTE=$(sudo ip route | grep ^default)
DOCKER_ROUTE=$(sudo ip route | grep ^$FIREZONE_DEV\/16)

sudo ip -4 route add $DEFAULT_ROUTE table $TABLE
sudo ip -4 route add $DOCKER_ROUTE table $TABLE

sudo ip -4 rule add from $FIREZONE_DEV table $TABLE

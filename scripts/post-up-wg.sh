#!/bin/bash
FIREZONE_DEV_V4='172.28.0.0/16'
FIREZONE_DEV_V6='2001:3990:3990::/64'
TABLE=333444
DEFAULT_ROUTE_V4=$(sudo ip -4 route | grep ^default)
DOCKER_ROUTE_V4=$(sudo ip -4 route | grep ^$FIREZONE_DEV_V4)
DEFAULT_ROUTE_V6=$(sudo ip -6 route | grep ^default)
DOCKER_ROUTE_V6=$(sudo ip -6 route | grep ^$FIREZONE_DEV_V6)

sudo ip -4 route add $DEFAULT_ROUTE_V4 table $TABLE
sudo ip -4 route add $DOCKER_ROUTE_V4 table $TABLE
sudo ip -6 route add $DOCKER_ROUTE_V6 table $TABLE
if [ ! -z "$DEFAULT_ROUTE_V6"]
then
    echo "BLAHHH"
    echo $DEFAULT_ROUTE_V6
    sudo ip -6 route add $DEFAULT_ROUTE_V6 table $TABLE
fi

sudo ip -4 rule add from $FIREZONE_DEV_V4 table $TABLE
sudo ip -6 rule add from $FIREZONE_DEV_V6 table $TABLE

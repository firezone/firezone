# Contributing Guide

Read this guide before opening a pull request.

## Table of Contents

1. Prerequisites
  1. Vagrant
  2. Consciousness
2. Development
  1. Provision the test VMs:
    ```bash
    > vagrant up
    ```

  2. Start the WireGuard™ interface on the server:
    ```bash
    > vagrant ssh server
    # ... wait for SSH session to establish, then
    > sudo wg-quick up wg0
    ```

    You should see output like:
    ```
    [#] ip link add wg0 type wireguard
    [#] wg setconf wg0 /dev/fd/63
    [#] ip -4 address add 192.168.10.1/24 dev wg0
    [#] ip link set mtu 1420 up dev wg0
    [#] iptables -A FORWARD -i wg0 -j ACCEPT; iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE; ip6tables -A FORWARD -i wg0 -j ACCEPT; ip6tables -t nat -A POSTROUTING -o eth0 -j MASQUERADE
    ```

  3. Start the WireGuard interface on the client:
    ```bash
    > vagrant ssh client
    # ... wait for SSH session to establish, then
    > sudo wg-quick up wg0
    ```

    You should see output like:
    ```
    [#] ip link add wg0 type wireguard
    [#] wg setconf wg0 /dev/fd/63
    [#] ip -4 address add 192.168.10.2/32 dev wg0
    [#] ip link set mtu 1420 up dev wg0
    [#] resolvconf -a tun.wg0 -m 0 -x
    [#] wg set wg0 fwmark 51820
    [#] ip -6 route add ::/0 dev wg0 table 51820
    [#] ip -6 rule add not fwmark 51820 table 51820
    [#] ip -6 rule add table main suppress_prefixlength 0
    [#] ip6tables-restore -n
    [#] ip -4 route add 0.0.0.0/0 dev wg0 table 51820
    [#] ip -4 rule add not fwmark 51820 table 51820
    [#] ip -4 rule add table main suppress_prefixlength 0
    [#] sysctl -q net.ipv4.conf.all.src_valid_mark=1
    [#] iptables-restore -n
    ```

3. Testing
  TBD

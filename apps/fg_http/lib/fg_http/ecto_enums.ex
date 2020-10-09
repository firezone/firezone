import EctoEnum

# We only allow dropping or accepting packets for now
defenum(RuleActionEnum, :action, [:drop, :allow])

# See http://ipset.netfilter.org/iptables.man.html
defenum(RuleProtocolEnum, :protocol, [
  :all,
  :tcp,
  :udp,
  :udplite,
  :icmp,
  :icmpv6,
  :esp,
  :ah,
  :sctp,
  :mh
])

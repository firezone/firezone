use ip_packet::IpPacket;
use rangemap::RangeInclusiveSet;

use crate::messages::gateway::{Filter, Filters};

#[derive(Debug)]
pub(crate) enum FilterEngine {
    PermitAll,
    PermitSome(AllowRules),
}

#[derive(Debug)]
pub(crate) struct AllowRules {
    udp: RangeInclusiveSet<u16>,
    tcp: RangeInclusiveSet<u16>,
    icmp: bool,
}

impl FilterEngine {
    pub(crate) fn is_allowed(&self, packet: &IpPacket) -> bool {
        match self {
            FilterEngine::PermitAll => true,
            FilterEngine::PermitSome(filter_engine) => filter_engine.is_allowed(packet),
        }
    }

    pub(crate) fn with_filters<'a>(
        filters: impl Iterator<Item = &'a Filters> + Clone,
    ) -> FilterEngine {
        // Empty filters means permit all
        if filters.clone().any(|f| f.is_empty()) {
            return Self::PermitAll;
        }

        let mut allow_rules = AllowRules::new();
        allow_rules.add_filters(filters.flatten());

        Self::PermitSome(allow_rules)
    }
}

impl AllowRules {
    fn new() -> AllowRules {
        AllowRules {
            udp: RangeInclusiveSet::new(),
            tcp: RangeInclusiveSet::new(),
            icmp: false,
        }
    }

    fn is_allowed(&self, packet: &IpPacket) -> bool {
        if let Some(tcp) = packet.as_tcp() {
            return self.tcp.contains(&tcp.destination_port());
        }

        if let Some(udp) = packet.as_udp() {
            return self.udp.contains(&udp.destination_port());
        }

        if packet.is_icmp() || packet.is_icmpv6() {
            return self.icmp;
        }

        false
    }

    fn add_filters<'a>(&mut self, filters: impl IntoIterator<Item = &'a Filter>) {
        for filter in filters {
            match filter {
                Filter::Udp(range) => {
                    self.udp
                        .insert(range.port_range_start..=range.port_range_end);
                }
                Filter::Tcp(range) => {
                    self.tcp
                        .insert(range.port_range_start..=range.port_range_end);
                }
                Filter::Icmp => {
                    self.icmp = true;
                }
            }
        }
    }
}

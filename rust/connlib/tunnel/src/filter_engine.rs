use connlib_shared::messages::Filter;
use ip_packet::{ip::IpNextHeaderProtocols, IpPacket};
use rangemap::RangeInclusiveSet;

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
    pub(crate) fn empty() -> FilterEngine {
        Self::PermitSome(AllowRules::new())
    }

    pub(crate) fn is_allowed(&self, packet: &IpPacket) -> bool {
        match self {
            FilterEngine::PermitAll => true,
            FilterEngine::PermitSome(filter_engine) => filter_engine.is_allowed(packet),
        }
    }

    pub(crate) fn permit_all(&mut self) {
        *self = FilterEngine::PermitAll;
    }

    pub(crate) fn add_filters<'a>(&mut self, filters: impl IntoIterator<Item = &'a Filter>) {
        match self {
            FilterEngine::PermitAll => {}
            FilterEngine::PermitSome(filter_engine) => filter_engine.add_filters(filters),
        }
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
        match packet.next_header() {
            // Note: possible optimization here
            // if we want to get the port here, and we assume correct formatting
            // we can do packet.payload()[2..=3] (for UDP and TCP bytes 2 and 3 are the port)
            // but it might be a bit harder to read
            IpNextHeaderProtocols::Tcp => packet
                .as_tcp()
                .is_some_and(|p| self.tcp.contains(&p.get_destination())),
            IpNextHeaderProtocols::Udp => packet
                .as_udp()
                .is_some_and(|p| self.udp.contains(&p.get_destination())),
            IpNextHeaderProtocols::Icmp | IpNextHeaderProtocols::Icmpv6 => self.icmp,
            _ => false,
        }
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

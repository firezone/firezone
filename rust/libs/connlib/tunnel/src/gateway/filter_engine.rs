use ip_packet::{Protocol, UnsupportedProtocol};
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

#[derive(Debug, thiserror::Error)]
pub(crate) enum Filtered {
    #[error("TCP port is not in allowed range")]
    Tcp,
    #[error("UDP port is not in allowed range")]
    Udp,
    #[error("ICMP not allowed")]
    Icmp,
    #[error("Failed to evaluate filter")]
    UnsupportedProtocol(#[from] UnsupportedProtocol),
}

impl FilterEngine {
    pub(crate) fn apply(
        &self,
        protocol: Result<Protocol, UnsupportedProtocol>,
    ) -> Result<(), Filtered> {
        match self {
            FilterEngine::PermitAll => Ok(()),
            FilterEngine::PermitSome(filter_engine) => filter_engine.apply(protocol),
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

    fn apply(&self, protocol: Result<Protocol, UnsupportedProtocol>) -> Result<(), Filtered> {
        match protocol {
            Ok(Protocol::Tcp(port)) if self.tcp.contains(&port) => Ok(()),
            Ok(Protocol::Udp(port)) if self.udp.contains(&port) => Ok(()),
            Ok(Protocol::IcmpEcho(_)) if self.icmp => Ok(()),

            // If ICMP is allowed, we don't care about the specific ICMP type.
            // i.e. it doesn't have to be an echo request / reply.
            Err(
                UnsupportedProtocol::UnsupportedIcmpv4Type(_)
                | UnsupportedProtocol::UnsupportedIcmpv6Type(_),
            ) if self.icmp => Ok(()),

            Ok(Protocol::Tcp(_)) => Err(Filtered::Tcp),
            Ok(Protocol::Udp(_)) => Err(Filtered::Udp),
            Ok(Protocol::IcmpEcho(_)) => Err(Filtered::Icmp),

            Err(e) => Err(Filtered::UnsupportedProtocol(e)),
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

#[cfg(test)]
mod tests {
    use ip_packet::{Icmpv4Type, Icmpv6Type, icmpv4, icmpv6};

    use super::*;

    #[test]
    fn allows_icmpv4_destination_unreachable() {
        let filter = FilterEngine::PermitSome(AllowRules {
            udp: RangeInclusiveSet::default(),
            tcp: RangeInclusiveSet::default(),
            icmp: true,
        });

        let result = filter.apply(Err(UnsupportedProtocol::UnsupportedIcmpv4Type(
            Icmpv4Type::DestinationUnreachable(icmpv4::DestUnreachableHeader::Host),
        )));

        assert!(result.is_ok())
    }

    #[test]
    fn allows_icmpv6_destination_unreachable() {
        let filter = FilterEngine::PermitSome(AllowRules {
            udp: RangeInclusiveSet::default(),
            tcp: RangeInclusiveSet::default(),
            icmp: true,
        });

        let result = filter.apply(Err(UnsupportedProtocol::UnsupportedIcmpv6Type(
            Icmpv6Type::DestinationUnreachable(icmpv6::DestUnreachableCode::Address),
        )));

        assert!(result.is_ok())
    }

    #[test]
    fn icmp_false_blocks_other_icmp_messages() {
        let filter = FilterEngine::PermitSome(AllowRules {
            udp: RangeInclusiveSet::default(),
            tcp: RangeInclusiveSet::default(),
            icmp: false,
        });

        let result = filter.apply(Err(UnsupportedProtocol::UnsupportedIcmpv4Type(
            Icmpv4Type::TimestampRequest(icmpv4::TimestampMessage::from_bytes([0u8; 16])),
        )));

        assert!(result.is_err())
    }
}

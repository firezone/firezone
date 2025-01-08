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
    #[error(transparent)]
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
        match protocol? {
            Protocol::Tcp(port) if self.tcp.contains(&port) => Ok(()),
            Protocol::Udp(port) if self.udp.contains(&port) => Ok(()),
            Protocol::Icmp(_) if self.icmp => Ok(()),
            Protocol::Tcp(_) => Err(Filtered::Tcp),
            Protocol::Udp(_) => Err(Filtered::Udp),
            Protocol::Icmp(_) => Err(Filtered::Icmp),
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

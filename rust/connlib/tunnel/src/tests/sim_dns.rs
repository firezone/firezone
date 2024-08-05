use super::{
    sim_net::{host, Host},
    strategies::latency,
    sut::hickory_name_to_domain,
};
use connlib_shared::DomainName;
use firezone_relay::IpStack;
use hickory_proto::{
    op::Message,
    rr::{RData, Record, RecordType},
};
use proptest::{
    arbitrary::any,
    strategy::{Just, Strategy},
};
use snownet::Transmit;
use std::{
    borrow::Cow,
    collections::{BTreeMap, HashSet},
    fmt,
    net::{IpAddr, SocketAddr},
    time::Instant,
};
use uuid::Uuid;

pub(crate) fn dns_server_id() -> impl Strategy<Value = DnsServerId> {
    any::<u128>().prop_map(DnsServerId::from_u128)
}

pub(crate) fn ref_dns_host(addr: SocketAddr) -> impl Strategy<Value = Host<RefDns>> {
    let ip = addr.ip();
    let port = addr.port();

    host(
        Just(IpStack::from(ip)),
        Just(port),
        Just(RefDns {}),
        latency(50),
    )
}

#[derive(Debug, Clone)]
pub(crate) struct RefDns {}

#[derive(Debug)]
pub(crate) struct SimDns {}

impl SimDns {
    pub(crate) fn receive(
        &mut self,
        global_dns_records: &BTreeMap<DomainName, HashSet<IpAddr>>,
        transmit: Transmit,
        _now: Instant,
    ) -> Option<Transmit<'static>> {
        let mut query = Message::from_vec(&transmit.payload).ok()?;

        let mut response = Message::new();
        response.set_id(query.id());
        response.set_message_type(hickory_proto::op::MessageType::Response);

        for query in query.take_queries() {
            response.add_query(query.clone());

            let records = global_dns_records
                .get(&hickory_name_to_domain(query.name().clone()))
                .cloned()
                .into_iter()
                .flatten()
                .filter(|ip| {
                    #[allow(clippy::wildcard_enum_match_arm)]
                    match query.query_type() {
                        RecordType::A => ip.is_ipv4(),
                        RecordType::AAAA => ip.is_ipv6(),
                        _ => todo!(),
                    }
                })
                .map(|ip| match ip {
                    IpAddr::V4(v4) => RData::A(v4.into()),
                    IpAddr::V6(v6) => RData::AAAA(v6.into()),
                })
                .map(|rdata| Record::from_rdata(query.name().clone(), 86400_u32, rdata));

            response.add_answers(records);
        }

        let payload = response.to_vec().unwrap();

        Some(Transmit {
            src: Some(transmit.dst),
            dst: transmit.src.unwrap(),
            payload: Cow::Owned(payload),
        })
    }
}

#[derive(Hash, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub(crate) struct DnsServerId(Uuid);

impl DnsServerId {
    #[cfg(feature = "proptest")]
    pub fn from_u128(v: u128) -> Self {
        Self(Uuid::from_u128(v))
    }
}

impl fmt::Display for DnsServerId {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        if cfg!(feature = "proptest") {
            write!(f, "{:X}", self.0.as_u128())
        } else {
            write!(f, "{}", self.0)
        }
    }
}

impl fmt::Debug for DnsServerId {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        fmt::Display::fmt(&self, f)
    }
}

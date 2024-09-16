use super::{
    sim_net::{host, Host},
    strategies::latency,
};
use connlib_shared::DomainName;
use domain::{
    base::{
        iana::{Class, Rcode},
        Message, MessageBuilder, Record, Rtype, ToName as _, Ttl,
    },
    rdata::AllRecordData,
};
use firezone_relay::IpStack;
use proptest::{
    arbitrary::any,
    strategy::{Just, Strategy},
};
use snownet::Transmit;
use std::{
    borrow::Cow,
    collections::{BTreeMap, BTreeSet},
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
        global_dns_records: &BTreeMap<DomainName, BTreeSet<IpAddr>>,
        transmit: Transmit,
        _now: Instant,
    ) -> Option<Transmit<'static>> {
        let query = Message::from_octets(&transmit.payload).ok()?;

        let response = MessageBuilder::new_vec();
        let mut answers = response.start_answer(&query, Rcode::NOERROR).unwrap();

        let query = query.sole_question().unwrap();
        let name = query.qname().to_vec();
        let qtype = query.qtype();

        let records = global_dns_records
            .get(&name)
            .into_iter()
            .flatten()
            .filter(|ip| match qtype {
                Rtype::A => ip.is_ipv4(),
                Rtype::AAAA => ip.is_ipv6(),
                _ => todo!(),
            })
            .copied()
            .map(|ip| match ip {
                IpAddr::V4(v4) => AllRecordData::<Vec<_>, DomainName>::A(v4.into()),
                IpAddr::V6(v6) => AllRecordData::<Vec<_>, DomainName>::Aaaa(v6.into()),
            })
            .map(|rdata| Record::new(name.clone(), Class::IN, Ttl::from_days(1), rdata));

        for record in records {
            answers.push(record).unwrap();
        }

        let payload = answers.finish();

        tracing::debug!(%name, %qtype, "Responding to DNS query");

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

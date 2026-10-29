#![expect(
    clippy::unnecessary_wraps,
    reason = "Function signatures must align with the Linux impl."
)]

use anyhow::Result;
use std::net::{Ipv4Addr, Ipv6Addr};
use stun_codec::rfc5766::attributes::ChannelNumber;
use tracing::level_filters::LevelFilter;

use crate::ebpf::AttachMode;
use crate::{AllocationPort, ClientSocket, PeerSocket, ThroughputLimit};

pub struct Program {}

#[derive(Debug, Default, Clone, Copy)]
pub struct RateLimitedPackets {
    pub marked: u64,
    pub dropped: u64,
}

impl Program {
    pub fn try_load(
        _: &str,
        _: AttachMode,
        _: LevelFilter,
        _: Option<Ipv4Addr>,
        _: Option<Ipv6Addr>,
        _: Option<Ipv4Addr>,
        _: Option<Ipv6Addr>,
    ) -> Result<Self> {
        Err(anyhow::anyhow!("Platform not supported"))
    }

    pub fn add_channel_binding(
        &mut self,
        _: ClientSocket,
        _: ChannelNumber,
        _: PeerSocket,
        _: AllocationPort,
        _: Option<ThroughputLimit>,
    ) -> Result<()> {
        Ok(())
    }

    pub fn remove_channel_binding(
        &mut self,
        _: ClientSocket,
        _: ChannelNumber,
        _: PeerSocket,
        _: AllocationPort,
    ) -> Result<()> {
        Ok(())
    }

    pub fn rate_limited_packets(&self) -> Result<RateLimitedPackets> {
        Ok(RateLimitedPackets::default())
    }
}

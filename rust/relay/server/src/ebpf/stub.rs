#![expect(
    clippy::unnecessary_wraps,
    reason = "Function signatures must align with the Linux impl."
)]

use anyhow::Result;
use ebpf_shared::Config;
use stun_codec::rfc5766::attributes::ChannelNumber;

use crate::{AllocationPort, ClientSocket, PeerSocket};

pub struct Program {}

impl Program {
    pub fn try_load(_: &str) -> Result<Self> {
        Err(anyhow::anyhow!("Platform not supported"))
    }

    pub fn add_channel_binding(
        &mut self,
        _: ClientSocket,
        _: ChannelNumber,
        _: PeerSocket,
        _: AllocationPort,
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

    pub fn set_config(&mut self, _: Config) -> Result<()> {
        Ok(())
    }

    pub fn config(&self) -> Config {
        Config::default()
    }
}

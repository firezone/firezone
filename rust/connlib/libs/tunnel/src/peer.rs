use std::{net::IpAddr, sync::Arc};

use boringtun::noise::{Tunn, TunnResult};
use bytes::Bytes;
use ip_network::IpNetwork;
use ip_network_table::IpNetworkTable;
use libs_common::{error_type::ErrorType, Callbacks};
use parking_lot::Mutex;
use webrtc::data::data_channel::DataChannel;

use super::PeerConfig;

pub(crate) struct Peer {
    pub tunnel: Mutex<Tunn>,
    pub index: u32,
    pub allowed_ips: IpNetworkTable<()>,
    pub channel: Arc<DataChannel>,
}

impl Peer {
    pub(crate) async fn send_infallible<CB: Callbacks>(&self, data: &[u8]) {
        if let Err(e) = self.channel.write(&Bytes::copy_from_slice(data)).await {
            tracing::error!("Couldn't send packet to connected peer: {e}");
            CB::on_error(&e.into(), ErrorType::Recoverable);
        }
    }

    pub(crate) fn from_config(
        tunnel: Tunn,
        index: u32,
        config: &PeerConfig,
        channel: Arc<DataChannel>,
    ) -> Self {
        Self::new(Mutex::new(tunnel), index, config.ips.clone(), channel)
    }

    pub(crate) fn new(
        tunnel: Mutex<Tunn>,
        index: u32,
        ips: Vec<IpNetwork>,
        channel: Arc<DataChannel>,
    ) -> Peer {
        let mut allowed_ips = IpNetworkTable::new();
        for ip in ips {
            allowed_ips.insert(ip, ());
        }
        Peer {
            tunnel,
            index,
            allowed_ips,
            channel,
        }
    }

    pub(crate) fn update_timers<'a>(&self, dst: &'a mut [u8]) -> TunnResult<'a> {
        self.tunnel.lock().update_timers(dst)
    }

    pub(crate) fn is_allowed(&self, addr: impl Into<IpAddr>) -> bool {
        self.allowed_ips.longest_match(addr).is_some()
    }
}

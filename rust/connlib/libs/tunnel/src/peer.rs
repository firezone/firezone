use std::{net::IpAddr, sync::Arc};

use boringtun::noise::{Tunn, TunnResult};
use bytes::Bytes;
use chrono::{DateTime, Utc};
use ip_network::IpNetwork;
use ip_network_table::IpNetworkTable;
use libs_common::{
    messages::{Id, ResourceDescription},
    Callbacks, Result,
};
use parking_lot::{Mutex, RwLock};
use webrtc::data::data_channel::DataChannel;

use super::PeerConfig;

pub(crate) struct Peer {
    pub tunnel: Mutex<Tunn>,
    pub index: u32,
    pub allowed_ips: IpNetworkTable<()>,
    pub channel: Arc<DataChannel>,
    pub expires_at: Option<DateTime<Utc>>,
    pub conn_id: Id,
    // For now each peer manages a single resource(none in case of a client).
    // In the future (after firezone/firezone#1825) we will use a `ResourceTable`.
    pub resource: Option<ResourceDescription>,
    // Here we store the address that we obtained for the resource that the peer corresponds to.
    // This can have the following problem:
    // 1. Peer sends packet to address.com and it resolves to 1.1.1.1
    // 2. Now Peer sends another packet to address.com but it resolves to 2.2.2.2
    // 3. We receive an outstanding response(or push) from 1.1.1.1
    // This response(or push) is ignored, since we store only the last.
    // so, TODO: store multiple ips and expire them.
    // Note that this case is quite an unlikely edge case so I wouldn't prioritize this fix
    // TODO: Also check if there's any case where we want to talk to ipv4 and ipv6 from the same peer.
    pub translated_resource_address: RwLock<Option<IpAddr>>,
}

impl Peer {
    pub(crate) async fn send_infallible<CB: Callbacks>(&self, data: &[u8], callbacks: &CB) {
        if let Err(e) = self.channel.write(&Bytes::copy_from_slice(data)).await {
            tracing::error!("Couldn't send packet to connected peer: {e}");
            let _ = callbacks.on_error(&e.into());
        }
    }

    pub(crate) fn from_config(
        tunnel: Tunn,
        index: u32,
        config: &PeerConfig,
        channel: Arc<DataChannel>,
        expires_at: Option<DateTime<Utc>>,
        conn_id: Id,
        resource: Option<ResourceDescription>,
    ) -> Self {
        Self::new(
            Mutex::new(tunnel),
            index,
            config.ips.clone(),
            channel,
            expires_at,
            conn_id,
            resource,
        )
    }

    pub(crate) fn new(
        tunnel: Mutex<Tunn>,
        index: u32,
        ips: Vec<IpNetwork>,
        channel: Arc<DataChannel>,
        expires_at: Option<DateTime<Utc>>,
        conn_id: Id,
        resource: Option<ResourceDescription>,
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
            expires_at,
            conn_id,
            resource,
            translated_resource_address: Default::default(),
        }
    }

    pub(crate) fn update_timers<'a>(&self, dst: &'a mut [u8]) -> TunnResult<'a> {
        self.tunnel.lock().update_timers(dst)
    }

    pub(crate) async fn shutdown(&self) -> Result<()> {
        self.channel.close().await?;
        Ok(())
    }

    pub(crate) fn is_valid(&self) -> bool {
        !self
            .expires_at
            .is_some_and(|expires_at| expires_at <= Utc::now())
    }

    pub(crate) fn is_allowed(&self, addr: IpAddr) -> bool {
        self.allowed_ips.longest_match(addr).is_some()
    }

    pub(crate) fn update_translated_resource_address(&self, addr: IpAddr) {
        if !self
            .translated_resource_address
            .read()
            .is_some_and(|stored| stored == addr)
        {
            *self.translated_resource_address.write() = Some(addr);
        }
    }
}

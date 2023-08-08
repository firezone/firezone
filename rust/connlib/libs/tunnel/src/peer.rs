use std::{collections::HashMap, net::IpAddr, sync::Arc};

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

use crate::resource_table::ResourceTable;

use super::PeerConfig;

type ExpiryingResource = (ResourceDescription, DateTime<Utc>);

pub(crate) struct Peer {
    pub tunnel: Mutex<Tunn>,
    pub index: u32,
    pub allowed_ips: RwLock<IpNetworkTable<()>>,
    pub channel: Arc<DataChannel>,
    pub conn_id: Id,
    pub resources: Option<RwLock<ResourceTable<ExpiryingResource>>>,
    // Here we store the address that we obtained for the resource that the peer corresponds to.
    // This can have the following problem:
    // 1. Peer sends packet to address.com and it resolves to 1.1.1.1
    // 2. Now Peer sends another packet to address.com but it resolves to 2.2.2.2
    // 3. We receive an outstanding response(or push) from 1.1.1.1
    // This response(or push) is ignored, since we store only the last.
    // so, TODO: store multiple ips and expire them.
    // Note that this case is quite an unlikely edge case so I wouldn't prioritize this fix
    // TODO: Also check if there's any case where we want to talk to ipv4 and ipv6 from the same peer.
    pub translated_resource_addresses: RwLock<HashMap<IpAddr, Id>>,
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
        gateway_id: Id,
        resource: Option<(ResourceDescription, DateTime<Utc>)>,
    ) -> Self {
        Self::new(
            Mutex::new(tunnel),
            index,
            config.ips.clone(),
            channel,
            gateway_id,
            resource,
        )
    }

    pub(crate) fn new(
        tunnel: Mutex<Tunn>,
        index: u32,
        ips: Vec<IpNetwork>,
        channel: Arc<DataChannel>,
        gateway_id: Id,
        resource: Option<(ResourceDescription, DateTime<Utc>)>,
    ) -> Peer {
        let mut allowed_ips = IpNetworkTable::new();
        for ip in ips {
            allowed_ips.insert(ip, ());
        }
        let allowed_ips = RwLock::new(allowed_ips);
        let resources = resource.and_then(|r| {
            let mut resource_table = ResourceTable::new();
            resource_table.insert(r);
            Some(RwLock::new(resource_table))
        });
        Peer {
            tunnel,
            index,
            allowed_ips,
            channel,
            conn_id: gateway_id,
            resources,
            translated_resource_addresses: Default::default(),
        }
    }

    pub(crate) fn get_translation(&self, ip: IpAddr) -> Option<ResourceDescription> {
        let id = self.translated_resource_addresses.read().get(&ip).cloned();
        self.resources.as_ref().and_then(|resources| {
            id.and_then(|id| resources.read().get_by_id(&id).map(|r| r.0.clone()))
        })
    }

    pub(crate) fn add_allowed_ip(&self, ip: IpNetwork) {
        self.allowed_ips.write().insert(ip, ());
    }

    pub(crate) fn update_timers<'a>(&self, dst: &'a mut [u8]) -> TunnResult<'a> {
        self.tunnel.lock().update_timers(dst)
    }

    pub(crate) async fn shutdown(&self) -> Result<()> {
        self.channel.close().await?;
        Ok(())
    }

    pub(crate) fn is_emptied(&self) -> bool {
        self.resources.as_ref().is_some_and(|r| r.read().is_empty())
    }

    pub(crate) fn expire_resources(&self) {
        if let Some(resources) = &self.resources {
            // TODO: We could move this to resource_table and make it way faster
            let expire_resources: Vec<_> = resources
                .read()
                .values()
                .filter(|(_, e)| e <= &Utc::now())
                .cloned()
                .collect();
            {
                // Oh oh! 2 Mutexes
                let mut resources = resources.write();
                let mut translated_resource_addresses = self.translated_resource_addresses.write();
                for r in expire_resources {
                    resources.cleanup_resource(&r);
                    translated_resource_addresses.retain(|_, &mut i| r.0.id() != i);
                }
            }
        }
    }

    pub(crate) fn add_resource(&self, resource: ResourceDescription, expires_at: DateTime<Utc>) {
        if let Some(resources) = &self.resources {
            resources.write().insert((resource, expires_at))
        }
    }

    pub(crate) fn is_allowed(&self, addr: IpAddr) -> bool {
        self.allowed_ips.read().longest_match(addr).is_some()
    }

    pub(crate) fn update_translated_resource_address(&self, id: Id, addr: IpAddr) {
        self.translated_resource_addresses.write().insert(addr, id);
    }
}

use crate::{
    control_protocol::insert_peers,
    dns::is_subdomain,
    peer::{PacketTransformGateway, Peer},
    GatewayState, Tunnel,
};

use boringtun::x25519::PublicKey;
use chrono::{DateTime, Utc};
use connlib_shared::{
    messages::{
        Answer, ClientId, ClientPayload, ConnectionAccepted, DomainResponse, Relay,
        ResourceAccepted, ResourceDescription, SecretKey,
    },
    Callbacks, Dname, Error, Result,
};
use ip_network::IpNetwork;
use secrecy::ExposeSecret;
use snownet::{Credentials, Offer, Server};
use std::{collections::HashSet, sync::Arc};

// TODO:
// #[tracing::instrument(level = "trace", skip(ice))]
// fn set_connection_state_update(ice: &Arc<RTCIceTransport>, client_id: ClientId) {
//     let ice = ice.clone();
//     ice.on_connection_state_change({
//         let ice = ice.clone();
//         Box::new(move |state| {
//             tracing::trace!(%state, "peer_state");
//             let ice = ice.clone();
//             Box::pin(async move {
//                 if state == RTCIceTransportState::Failed {
//                     if let Err(e) = ice.stop().await {
//                         tracing::warn!(err = ?e, "Couldn't stop ice client: {e:#}");
//                     }
//                 }
//             })
//         })
//     });
// }

impl<CB> Tunnel<CB, GatewayState, Server, ClientId, PacketTransformGateway>
where
    CB: Callbacks + 'static,
{
    /// Accept a connection request from a client.
    ///
    /// Sets a connection to a remote SDP, creates the local SDP
    /// and returns it.
    ///
    /// # Returns
    /// The connection details
    pub async fn set_peer_connection_request(
        &self,
        client_payload: ClientPayload,
        ips: Vec<IpNetwork>,
        public_key: PublicKey,
        preshared_key: SecretKey,
        relays: Vec<Relay>,
        client_id: ClientId,
        expires_at: Option<DateTime<Utc>>,
        resource: ResourceDescription,
    ) -> Result<ConnectionAccepted> {
        // TODO:
        // set_connection_state_update(&ice, client_id);

        // TODO:
        // let previous_ice = self
        //     .peer_connections
        //     .lock()
        //     .insert(client_id, Arc::clone(&ice));
        // if let Some(ice) = previous_ice {
        //     // If we had a previous on-going connection we stop it.
        //     // Note that ice.stop also closes the gatherer.
        //     // we only have to do this on the gateway because clients can query
        //     // twice for initiating connections since they can close/reopen suddenly
        //     // however, gateways never initiate connection requests
        //     let _ = ice.stop().await;
        // }

        let resource_addresses = match &resource {
            ResourceDescription::Dns(r) => {
                let Some(domain) = client_payload.domain.clone() else {
                    return Err(Error::ControlProtocolError);
                };

                if !is_subdomain(&domain, &r.address) {
                    return Err(Error::InvalidResource);
                }

                tokio::task::spawn_blocking(move || resolve_addresses(&domain.to_string()))
                    .await??
            }
            ResourceDescription::Cidr(ref cidr) => vec![cidr.address],
        };

        let mut stun_servers: HashSet<_> = turn(&relays).iter().map(|r| r.0).collect();
        stun_servers.extend(stun(&relays));
        let answer = self.connections.lock().connection_pool.accept_connection(
            client_id,
            Offer {
                session_key: preshared_key.expose_secret().0.into(),
                credentials: Credentials {
                    username: client_payload.ice_parameters.username,
                    password: client_payload.ice_parameters.password,
                },
            },
            public_key,
            stun_servers,
            turn(&relays),
        );

        self.new_peer(
            ips,
            client_id,
            resource,
            expires_at,
            resource_addresses.clone(),
        )?;

        Ok(ConnectionAccepted {
            ice_parameters: Answer {
                username: answer.credentials.username,
                password: answer.credentials.password,
            },
            domain_response: client_payload.domain.map(|domain| DomainResponse {
                domain,
                address: resource_addresses
                    .into_iter()
                    .map(|ip| ip.network_address())
                    .collect(),
            }),
        })
    }

    pub async fn allow_access(
        &self,
        resource: ResourceDescription,
        client_id: ClientId,
        expires_at: Option<DateTime<Utc>>,
        domain: Option<Dname>,
    ) -> Option<ResourceAccepted> {
        let Some(peer) = self
            .role_state
            .lock()
            .peers_by_ip
            .iter_mut()
            .find_map(|(_, p)| (p.conn_id == client_id).then_some(p.clone()))
        else {
            return None;
        };

        let addresses = match &resource {
            ResourceDescription::Dns(r) => {
                let Some(domain) = domain.clone() else {
                    return None;
                };

                if !is_subdomain(&domain, &r.address) {
                    return None;
                }

                tokio::task::spawn_blocking(move || resolve_addresses(&domain.to_string()))
                    .await
                    .ok()?
                    .ok()?
            }
            ResourceDescription::Cidr(cidr) => vec![cidr.address],
        };

        for address in &addresses {
            peer.transform
                .add_resource(*address, resource.clone(), expires_at);
        }

        if let Some(domain) = domain {
            return Some(ResourceAccepted {
                domain_response: DomainResponse {
                    domain,
                    address: addresses.iter().map(|i| i.network_address()).collect(),
                },
            });
        }

        None
    }

    fn new_peer(
        &self,
        ips: Vec<IpNetwork>,
        client_id: ClientId,
        resource: ResourceDescription,
        expires_at: Option<DateTime<Utc>>,
        resource_addresses: Vec<IpNetwork>,
    ) -> Result<()> {
        tracing::trace!(?ips, "new_data_channel_open");

        let peer = Arc::new(Peer::new(
            ips.clone(),
            client_id,
            PacketTransformGateway::default(),
        ));

        for address in resource_addresses {
            peer.transform
                .add_resource(address, resource.clone(), expires_at);
        }

        self.connections
            .lock()
            .peers_by_id
            .insert(client_id, Arc::clone(&peer));
        insert_peers(&mut self.role_state.lock().peers_by_ip, &ips, peer);

        Ok(())
    }
}

#[cfg(target_os = "windows")]
fn resolve_addresses(_: &str) -> std::io::Result<Vec<IpNetwork>> {
    unimplemented!()
}

#[cfg(not(target_os = "windows"))]
fn resolve_addresses(addr: &str) -> std::io::Result<Vec<IpNetwork>> {
    use libc::{AF_INET, AF_INET6};
    let addr_v4: std::io::Result<Vec<_>> = resolve_address_family(addr, AF_INET)
        .map_err(|e| e.into())
        .and_then(|a| a.collect());
    let addr_v6: std::io::Result<Vec<_>> = resolve_address_family(addr, AF_INET6)
        .map_err(|e| e.into())
        .and_then(|a| a.collect());
    match (addr_v4, addr_v6) {
        (Ok(v4), Ok(v6)) => Ok(v6
            .iter()
            .map(|a| a.sockaddr.ip().into())
            .chain(v4.iter().map(|a| a.sockaddr.ip().into()))
            .collect()),
        (Ok(v4), Err(_)) => Ok(v4.iter().map(|a| a.sockaddr.ip().into()).collect()),
        (Err(_), Ok(v6)) => Ok(v6.iter().map(|a| a.sockaddr.ip().into()).collect()),
        (Err(e), Err(_)) => Err(e),
    }
}

#[cfg(not(target_os = "windows"))]
use dns_lookup::{AddrInfoHints, AddrInfoIter, LookupError};

use super::{stun, turn};

#[cfg(not(target_os = "windows"))]
fn resolve_address_family(
    addr: &str,
    family: i32,
) -> std::result::Result<AddrInfoIter, LookupError> {
    use libc::SOCK_STREAM;

    dns_lookup::getaddrinfo(
        Some(addr),
        None,
        Some(AddrInfoHints {
            socktype: SOCK_STREAM,
            address: family,
            ..Default::default()
        }),
    )
}

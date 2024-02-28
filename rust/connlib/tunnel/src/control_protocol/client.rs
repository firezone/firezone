use std::{collections::HashSet, net::IpAddr, time::Instant};

use boringtun::x25519::PublicKey;
use connlib_shared::{
    messages::{
        Answer, ClientPayload, DomainResponse, GatewayId, Key, Offer, Relay, RequestConnection,
        ResourceDescription, ResourceId, ReuseConnection,
    },
    Callbacks,
};
use domain::base::Rtype;
use ip_network::IpNetwork;
use secrecy::{ExposeSecret, Secret};
use snownet::Client;

use crate::{
    client::DnsResource,
    device_channel::Device,
    dns,
    peer::PacketTransformClient,
    utils::{stun, turn},
};
use crate::{peer::Peer, ClientState, Error, Result, Tunnel};

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Request {
    NewConnection(RequestConnection),
    ReuseConnection(ReuseConnection),
}

impl<CB> Tunnel<CB, ClientState, Client, GatewayId>
where
    CB: Callbacks + 'static,
{
    /// Initiate an ice connection request.
    ///
    /// Given a resource id and a list of relay creates a [RequestConnection]
    /// and prepares the tunnel to handle the connection once initiated.
    ///
    /// # Parameters
    /// - `resource_id`: Id of the resource we are going to request the connection to.
    /// - `relays`: The list of relays used for that connection.
    ///
    /// # Returns
    /// A [RequestConnection] that should be sent to the gateway through the control-plane.
    #[tracing::instrument(level = "trace", skip_all, fields(%resource_id, %gateway_id))]
    pub fn request_connection(
        &mut self,
        resource_id: ResourceId,
        gateway_id: GatewayId,
        relays: Vec<Relay>,
    ) -> Result<Request> {
        tracing::trace!("request_connection");

        if let Some(connection) = self
            .role_state
            .attempt_to_reuse_connection(resource_id, gateway_id)?
        {
            // TODO: now we send reuse connections before connection is established but after
            // response is offered.
            // We need to consider new race conditions, such as connection failed after
            // reuse connection is sent.
            // Though I believe everything will work just fine like this.
            return Ok(Request::ReuseConnection(connection));
        }

        let domain = self
            .role_state
            .get_awaiting_connection_domain(&resource_id)?
            .clone();

        let offer = self.connections_state.node.new_connection(
            gateway_id,
            stun(&relays, |addr| {
                self.connections_state.sockets.can_handle(addr)
            }),
            turn(&relays, |addr| {
                self.connections_state.sockets.can_handle(addr)
            }),
        );

        Ok(Request::NewConnection(RequestConnection {
            resource_id,
            gateway_id,
            client_preshared_key: Secret::new(Key(*offer.session_key.expose_secret())),
            client_payload: ClientPayload {
                ice_parameters: Offer {
                    username: offer.credentials.username,
                    password: offer.credentials.password,
                },
                domain,
            },
        }))
    }

    fn new_peer(
        &mut self,
        resource_id: ResourceId,
        gateway_id: GatewayId,
        domain_response: Option<DomainResponse>,
    ) -> Result<()> {
        let ips = self.role_state.create_peer_config_for_new_connection(
            resource_id,
            gateway_id,
            &domain_response.as_ref().map(|d| d.domain.clone()),
        )?;

        let resource_ids = HashSet::from([resource_id]);
        let mut peer: Peer<_, PacketTransformClient, _> =
            Peer::new(gateway_id, Default::default(), &ips, resource_ids);
        peer.transform.set_dns(self.role_state.dns_mapping());
        self.role_state.peers.insert(peer, &[]);

        let peer_ips = if let Some(domain_response) = domain_response {
            self.dns_response(&resource_id, &domain_response, &gateway_id)?
        } else {
            ips
        };

        self.role_state
            .peers
            .add_ips_with_resource(&gateway_id, &peer_ips, &resource_id);

        Ok(())
    }

    /// Called when a response to [Tunnel::request_connection] is ready.
    ///
    /// Once this is called, if everything goes fine, a new tunnel should be started between the 2 peers.
    #[tracing::instrument(level = "trace", skip(self, gateway_public_key, resource_id))]
    pub fn received_offer_response(
        &mut self,
        resource_id: ResourceId,
        rtc_ice_params: Answer,
        domain_response: Option<DomainResponse>,
        gateway_public_key: PublicKey,
    ) -> Result<()> {
        tracing::trace!("received offer response");

        let gateway_id = self
            .role_state
            .gateway_by_resource(&resource_id)
            .ok_or(Error::UnknownResource)?;

        self.connections_state.node.accept_answer(
            gateway_id,
            gateway_public_key,
            snownet::Answer {
                credentials: snownet::Credentials {
                    username: rtc_ice_params.username,
                    password: rtc_ice_params.password,
                },
            },
            Instant::now(),
        );

        self.new_peer(resource_id, gateway_id, domain_response)?;

        Ok(())
    }

    fn dns_response(
        &mut self,
        resource_id: &ResourceId,
        domain_response: &DomainResponse,
        peer_id: &GatewayId,
    ) -> Result<Vec<IpNetwork>> {
        let peer = self
            .role_state
            .peers
            .get_mut(peer_id)
            .ok_or(Error::ControlProtocolError)?;

        let resource_description = self
            .role_state
            .resource_ids
            .get(resource_id)
            .ok_or(Error::UnknownResource)?
            .clone();

        let ResourceDescription::Dns(resource_description) = resource_description else {
            // We should never get a domain_response for a CIDR resource!
            return Err(Error::ControlProtocolError);
        };

        let resource_description =
            DnsResource::from_description(&resource_description, domain_response.domain.clone());

        let addrs: HashSet<_> = domain_response
            .address
            .iter()
            .filter_map(|external_ip| {
                peer.transform
                    .get_or_assign_translation(external_ip, &mut self.role_state.ip_provider)
            })
            .collect();

        self.role_state
            .dns_resources_internal_ips
            .insert(resource_description.clone(), addrs.clone());

        let ips: Vec<IpNetwork> = addrs.iter().copied().map(Into::into).collect();

        if let Some(device) = self.device.as_ref() {
            send_dns_answer(
                &mut self.role_state,
                Rtype::Aaaa,
                device,
                &resource_description,
                &addrs,
            );

            send_dns_answer(
                &mut self.role_state,
                Rtype::A,
                device,
                &resource_description,
                &addrs,
            );
        }

        Ok(ips)
    }

    #[tracing::instrument(level = "trace", skip(self, resource_id))]
    pub fn received_domain_parameters(
        &mut self,
        resource_id: ResourceId,
        domain_response: DomainResponse,
    ) -> Result<()> {
        let gateway_id = self
            .role_state
            .gateway_by_resource(&resource_id)
            .ok_or(Error::UnknownResource)?;

        let peer_ips = self.dns_response(&resource_id, &domain_response, &gateway_id)?;

        self.role_state
            .peers
            .add_ips_with_resource(&gateway_id, &peer_ips, &resource_id);

        Ok(())
    }
}

fn send_dns_answer(
    role_state: &mut ClientState,
    qtype: Rtype,
    device: &Device,
    resource_description: &DnsResource,
    addrs: &HashSet<IpAddr>,
) {
    let packet = role_state
        .deferred_dns_queries
        .remove(&(resource_description.clone(), qtype));
    if let Some(packet) = packet {
        let Some(packet) = dns::create_local_answer(addrs, packet) else {
            return;
        };
        if let Err(e) = device.write(packet) {
            tracing::error!(err = ?e, "error writing packet: {e:#?}");
        }
    }
}

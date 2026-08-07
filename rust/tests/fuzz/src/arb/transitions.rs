use std::{collections::BTreeMap, time::Duration};

use connlib_model::Site;
use dns_types::DomainName;
use ip_network::{Ipv4Network, Ipv6Network};
use smallvec::SmallVec;
use tunnel_proto::messages::client::DevicePoolMember;

use super::context::Generator;
use super::topology::{
    arb_dns_record_set, arb_relays, arb_socket_ip_stack, arb_two_relays, pick_site, with_interface,
};
use super::values::{
    arb_address_description, arb_cidr_resource_address, arb_compatible_upstream_do53_servers,
    arb_different_address_description, arb_different_cidr_resource_address,
    arb_different_dns_resource_address, arb_different_filters, arb_different_ip_stack_kind,
    arb_domain_name_string, arb_ip_stack_kind, arb_system_dns_servers, arb_upstream_doh_servers,
};
use super::{dns_queries, packets};
use crate::reference::ReferenceState;
use crate::resource::{
    CidrResource, CidrResourceEdit, CidrResourceValue, DnsResource, DnsResourceEdit,
    DnsResourceValue, DynamicDevicePoolResource, DynamicDevicePoolResourceEdit,
    DynamicDevicePoolResourceValue, Resource, ResourceEdit, ResourceTypeEdit,
    StaticDevicePoolResource, StaticDevicePoolResourceEdit, StaticDevicePoolResourceValue,
};
use crate::sim_net::{EdgeConfig, Host};
use crate::transition::Transition;

#[derive(Clone, Copy, Debug)]
enum TransitionKind {
    // Always-legal.
    UpdateSystemDnsServers,
    UpdateUpstreamDo53Servers,
    UpdateUpstreamDoHServers,
    UpdateUpstreamSearchDomain,
    RoamClient,
    DeployNewRelays,
    UpdateRelayPresence,
    PartitionRelaysFromPortal,
    RebootRelaysWhilePartitioned,
    Idle,
    // State-gated.
    AddResource,
    EditResource,
    RemoveResource,
    ReconnectPortal,
    RestartClient,
    SetInternetResourceState,
    DeauthorizeWhileGatewayIsPartitioned,
    UpdateDnsRecords,
    SendPacket,
    SendUdpPacketOnFlow,
    SendUnroutablePacket,
    SendDnsQuery,
    SendTruncatedUdpDnsQuery,
}

pub(super) fn generate(g: &mut Generator, state: &ReferenceState) -> Option<Transition> {
    let addable_resources = state.resources_unknown_to_all_clients();
    let editable_resources = state.editable_resources_on_any_client();
    let removable_resources = state.removable_resource_ids();
    let deauthorizable_resources = state.deauthorizable_resource_ids();
    let client_ids = state.all_client_ids();
    let dns_record_domains = state.dns_resource_domains();
    let packet_targets = packets::targets(state);
    let udp_flows = state.udp_flows();
    let dns_query_targets = dns_queries::targets(state);
    let truncated_dns_query_targets = state.reachable_dns_servers();

    // Build the legal action list. Data-plane actions stay more frequent because
    // they drive most of the tunnel state machine; libFuzzer chooses the concrete
    // destination, protocol and fields from subsequent bytes.
    use TransitionKind as K;

    let legal = [
        Some((K::UpdateSystemDnsServers, 1)),
        Some((K::UpdateUpstreamDo53Servers, 1)),
        Some((K::UpdateUpstreamDoHServers, 1)),
        Some((K::UpdateUpstreamSearchDomain, 1)),
        Some((K::RoamClient, 1)),
        Some((K::DeployNewRelays, 1)),
        (state.relays.len() >= 2).then_some((K::UpdateRelayPresence, 1)),
        Some((K::PartitionRelaysFromPortal, 1)),
        Some((K::RebootRelaysWhilePartitioned, 1)),
        Some((K::Idle, 1)),
        (!addable_resources.is_empty()).then_some((K::AddResource, 5)),
        (!editable_resources.is_empty()).then_some((K::EditResource, 7)),
        (!removable_resources.is_empty()).then_some((K::RemoveResource, 1)),
        (!deauthorizable_resources.is_empty())
            .then_some((K::DeauthorizeWhileGatewayIsPartitioned, 1)),
        (!client_ids.is_empty()).then_some((K::ReconnectPortal, 1)),
        (!client_ids.is_empty()).then_some((K::RestartClient, 1)),
        (!client_ids.is_empty()).then_some((K::SetInternetResourceState, 1)),
        (!dns_record_domains.is_empty()).then_some((K::UpdateDnsRecords, 5)),
        (!packet_targets.is_empty()).then_some((K::SendPacket, 50)),
        (!udp_flows.is_empty()).then_some((K::SendUdpPacketOnFlow, 25)),
        (!state.clients.is_empty() && !state.gateways.is_empty())
            .then_some((K::SendUnroutablePacket, 5)),
        (!dns_query_targets.is_empty()).then_some((K::SendDnsQuery, 10)),
        (!truncated_dns_query_targets.is_empty()).then_some((K::SendTruncatedUdpDnsQuery, 2)),
    ]
    .into_iter()
    .flatten()
    .collect::<SmallVec<[_; 23]>>();

    // Weighted pick over the legal list.
    let kind = weighted_choose(g, &legal)?;

    // Generate only the chosen arm's payload from the following bytes.
    let transition = match kind {
        K::UpdateSystemDnsServers => Transition::UpdateSystemDnsServers {
            servers: arb_system_dns_servers(g),
        },
        K::UpdateUpstreamDo53Servers => {
            Transition::UpdateUpstreamDo53Servers(arb_compatible_upstream_do53_servers(g, state))
        }
        K::UpdateUpstreamDoHServers => {
            Transition::UpdateUpstreamDoHServers(arb_upstream_doh_servers(g))
        }
        K::UpdateUpstreamSearchDomain => {
            let domains = state.portal.dns_resources();
            let candidates = domains
                .filter_map(|r| {
                    let (_, s) = r.address.split_once('.')?;
                    DomainName::vec_from_str(s).ok()
                })
                .collect::<Vec<_>>();
            let chosen = if candidates.is_empty() || !g.flip(50) {
                None
            } else {
                let idx = g.choose_index(candidates.len());
                Some(candidates[idx].clone())
            };
            Transition::UpdateUpstreamSearchDomain(chosen)
        }
        K::RoamClient => {
            let client_id = client_ids[g.choose_index(client_ids.len())];
            let (ip4, ip6) = arb_socket_ip_stack(g);
            // Mirror `transition::roam_client`: both windows in 0..3000ms.
            let dead_window = Duration::from_millis(g.count(0, 2999) as u64);
            let portal_window = Duration::from_millis(g.count(0, 2999) as u64);
            Transition::RoamClient {
                client_id,
                ip4,
                ip6,
                nat_ip4: g.nat_ip4(),
                dead_window,
                portal_window,
            }
        }
        K::DeployNewRelays => Transition::DeployNewRelays(arb_relays(g)),
        K::UpdateRelayPresence => {
            let relay_id = state
                .relays
                .keys()
                .nth(g.choose_index(state.relays.len()))
                .unwrap();

            Transition::UpdateRelayPresence {
                disconnected: [*relay_id].into_iter().collect(),
                connected: arb_two_relays(g),
            }
        }
        K::PartitionRelaysFromPortal => Transition::PartitionRelaysFromPortal,
        K::RebootRelaysWhilePartitioned => {
            // Reboot the *existing* relays with fresh credentials (same ids).
            let relays = state
                .relays
                .keys()
                .copied()
                .map(|id| {
                    let seed = g.u64();
                    let latency = g.latency(50);
                    let host = Host::new(seed, latency, 3478, EdgeConfig::Open, g.nat_ip4());
                    let host = with_interface(host, Some(g.socket_ip4()), Some(g.socket_ip6()));
                    (id, host)
                })
                .collect::<BTreeMap<_, _>>();
            Transition::RebootRelaysWhilePartitioned(relays)
        }
        K::Idle => {
            if g.bool() {
                Transition::DropNextWirePacket
            } else {
                Transition::Idle
            }
        }
        K::AddResource => {
            let resource = addable_resources[g.choose_index(addable_resources.len())].clone();
            Transition::AddResource(resource)
        }
        K::EditResource => {
            let resource = editable_resources[g.choose_index(editable_resources.len())].clone();
            Transition::EditResource(arb_resource_edit(g, state, resource))
        }
        K::RemoveResource => {
            let id = removable_resources[g.choose_index(removable_resources.len())];
            Transition::RemoveResource(id)
        }
        K::DeauthorizeWhileGatewayIsPartitioned => {
            let id = deauthorizable_resources[g.choose_index(deauthorizable_resources.len())];
            Transition::DeauthorizeWhileGatewayIsPartitioned(id)
        }
        K::ReconnectPortal => {
            let client_id = client_ids[g.choose_index(client_ids.len())];
            Transition::ReconnectPortal { client_id }
        }
        K::RestartClient => {
            let client_id = client_ids[g.choose_index(client_ids.len())];
            let key = g.fresh_private_key();
            Transition::RestartClient { client_id, key }
        }
        K::SetInternetResourceState => {
            let client_id = client_ids[g.choose_index(client_ids.len())];
            let active = g.bool();
            Transition::SetInternetResourceState { client_id, active }
        }
        K::UpdateDnsRecords => {
            let domain = dns_record_domains[g.choose_index(dns_record_domains.len())].clone();
            let records = arb_dns_record_set(g);
            Transition::UpdateDnsRecords { domain, records }
        }
        K::SendPacket => {
            let target = packet_targets[g.choose_index(packet_targets.len())].clone();
            packets::generate(g, target)
        }
        K::SendUdpPacketOnFlow => {
            let flow = udp_flows[g.choose_index(udp_flows.len())].clone();
            let probe_id = g.fresh_probe_id();

            Transition::SendUdpPacketOnFlow { flow, probe_id }
        }
        K::SendUnroutablePacket => super::packet_inputs::generate(g, state),
        K::SendDnsQuery => {
            let target = dns_query_targets[g.choose_index(dns_query_targets.len())].clone();
            dns_queries::generate(g, target, state)
        }
        K::SendTruncatedUdpDnsQuery => {
            let target = truncated_dns_query_targets
                [g.choose_index(truncated_dns_query_targets.len())]
            .clone();
            dns_queries::generate_truncated(g, target)
        }
    };

    Some(transition)
}

fn arb_resource_edit(
    g: &mut Generator,
    state: &ReferenceState,
    resource: Resource,
) -> ResourceEdit {
    if g.flip(25) {
        let new_resource = arb_resource_with_different_type(g, state, &resource);

        return ResourceEdit::Type(ResourceTypeEdit {
            old_resource: resource,
            new_resource,
        });
    }

    match resource {
        Resource::Dns(resource) => {
            let fields = resource
                .values()
                .into_iter()
                .filter(|field| match field {
                    DnsResourceValue::Id(_) => {
                        unreachable!("resource identity is not editable")
                    }
                    DnsResourceValue::Address(_) => true,
                    DnsResourceValue::Name(_) => true,
                    DnsResourceValue::AddressDescription(_) => true,
                    DnsResourceValue::Sites(_) => has_alternative_site(&resource.sites, state),
                    DnsResourceValue::IpStack(_) => true,
                    DnsResourceValue::Filters(_) => true,
                })
                .collect::<SmallVec<[_; 6]>>();
            let index = g.choose_index(fields.len());
            let field = fields.into_iter().nth(index).expect("a valid field index");
            let value = match field {
                DnsResourceValue::Id(_) => unreachable!("resource identity is not editable"),
                DnsResourceValue::Address(_) => DnsResourceValue::Address(
                    arb_different_dns_resource_address(g, &resource.address),
                ),
                DnsResourceValue::Name(_) => {
                    DnsResourceValue::Name(arb_different_name(g, &resource.name))
                }
                DnsResourceValue::AddressDescription(_) => DnsResourceValue::AddressDescription(
                    arb_different_address_description(g, &resource.address_description),
                ),
                DnsResourceValue::Sites(_) => {
                    DnsResourceValue::Sites(arb_different_site(g, &resource.sites, state))
                }
                DnsResourceValue::IpStack(_) => {
                    DnsResourceValue::IpStack(arb_different_ip_stack_kind(g, resource.ip_stack))
                }
                DnsResourceValue::Filters(_) => {
                    DnsResourceValue::Filters(arb_different_filters(g, &resource.filters))
                }
            };

            ResourceEdit::Dns(DnsResourceEdit { resource, value })
        }
        Resource::Cidr(resource) => {
            let fields = resource
                .values()
                .into_iter()
                .filter(|field| match field {
                    CidrResourceValue::Id(_) => {
                        unreachable!("resource identity is not editable")
                    }
                    CidrResourceValue::Address(_) => true,
                    CidrResourceValue::Name(_) => true,
                    CidrResourceValue::AddressDescription(_) => true,
                    CidrResourceValue::Sites(_) => has_alternative_site(&resource.sites, state),
                    CidrResourceValue::Filters(_) => true,
                })
                .collect::<SmallVec<[_; 5]>>();
            let index = g.choose_index(fields.len());
            let field = fields.into_iter().nth(index).expect("a valid field index");
            let value = match field {
                CidrResourceValue::Id(_) => unreachable!("resource identity is not editable"),
                CidrResourceValue::Address(_) => CidrResourceValue::Address(
                    arb_different_cidr_resource_address(g, resource.address),
                ),
                CidrResourceValue::Name(_) => {
                    CidrResourceValue::Name(arb_different_name(g, &resource.name))
                }
                CidrResourceValue::AddressDescription(_) => CidrResourceValue::AddressDescription(
                    arb_different_address_description(g, &resource.address_description),
                ),
                CidrResourceValue::Sites(_) => {
                    CidrResourceValue::Sites(arb_different_site(g, &resource.sites, state))
                }
                CidrResourceValue::Filters(_) => {
                    CidrResourceValue::Filters(arb_different_filters(g, &resource.filters))
                }
            };

            ResourceEdit::Cidr(CidrResourceEdit { resource, value })
        }
        Resource::StaticDevicePool(resource) => {
            let fields = resource.values();
            let index = g.choose_index(fields.len());
            let field = fields.into_iter().nth(index).expect("a valid field index");
            let value = match field {
                StaticDevicePoolResourceValue::Id(_) => {
                    unreachable!("resource identity is not editable")
                }
                StaticDevicePoolResourceValue::Name(_) => {
                    StaticDevicePoolResourceValue::Name(arb_different_name(g, &resource.name))
                }
                StaticDevicePoolResourceValue::Devices(_) => {
                    StaticDevicePoolResourceValue::Devices(arb_different_static_pool_members(
                        g, state, &resource,
                    ))
                }
                StaticDevicePoolResourceValue::Filters(_) => {
                    StaticDevicePoolResourceValue::Filters(arb_different_filters(
                        g,
                        &resource.filters,
                    ))
                }
            };

            ResourceEdit::StaticDevicePool(StaticDevicePoolResourceEdit { resource, value })
        }
        Resource::DynamicDevicePool(resource) => {
            let fields = resource.values();
            let index = g.choose_index(fields.len());
            let field = fields.into_iter().nth(index).expect("a valid field index");
            let value = match field {
                DynamicDevicePoolResourceValue::Id(_) => {
                    unreachable!("resource identity is not editable")
                }
                DynamicDevicePoolResourceValue::Name(_) => {
                    DynamicDevicePoolResourceValue::Name(arb_different_name(g, &resource.name))
                }
                DynamicDevicePoolResourceValue::Address(_) => {
                    DynamicDevicePoolResourceValue::Address(arb_different_dns_resource_address(
                        g,
                        &resource.address,
                    ))
                }
                DynamicDevicePoolResourceValue::Filters(_) => {
                    DynamicDevicePoolResourceValue::Filters(arb_different_filters(
                        g,
                        &resource.filters,
                    ))
                }
            };

            ResourceEdit::DynamicDevicePool(DynamicDevicePoolResourceEdit { resource, value })
        }
        Resource::Internet(_) => {
            unreachable!("the Portal API does not allow editing the Internet Resource")
        }
    }
}

fn has_alternative_site(current: &[Site], state: &ReferenceState) -> bool {
    state
        .regular_sites()
        .iter()
        .any(|site| current.len() != 1 || current.first() != Some(site))
}

fn arb_different_site(g: &mut Generator, current: &[Site], state: &ReferenceState) -> Vec<Site> {
    let sites = state
        .regular_sites()
        .iter()
        .filter(|site| current.len() != 1 || current.first() != Some(*site))
        .collect::<SmallVec<[_; 3]>>();
    let site = sites[g.choose_index(sites.len())];

    vec![site.clone()]
}

fn arb_different_name(g: &mut Generator, current: &str) -> String {
    let name = g.lower_ascii(4, 10);

    if name != current {
        return name;
    }

    "changed".to_owned()
}

fn arb_different_static_pool_members(
    g: &mut Generator,
    state: &ReferenceState,
    resource: &StaticDevicePoolResource,
) -> Vec<DevicePoolMember> {
    let devices = packets::arb_static_pool_members(g, state, resource);

    if devices != resource.devices {
        return devices;
    }

    if !resource.devices.is_empty() {
        return Vec::new();
    }

    let (id, client) = state
        .clients
        .first_key_value()
        .expect("at least one client");
    let client = client.inner();

    vec![DevicePoolMember {
        id: *id,
        ipv4: Ipv4Network::new(client.tunnel_ip4, 32).unwrap(),
        ipv6: Ipv6Network::new(client.tunnel_ip6, 128).unwrap(),
    }]
}

fn arb_resource_with_different_type(
    g: &mut Generator,
    state: &ReferenceState,
    resource: &Resource,
) -> Resource {
    #[derive(Clone, Copy)]
    enum ResourceType {
        Cidr,
        Dns,
        StaticDevicePool,
        DynamicDevicePool,
    }

    let resource_type = match resource {
        Resource::Cidr(_) => [
            ResourceType::Dns,
            ResourceType::StaticDevicePool,
            ResourceType::DynamicDevicePool,
        ][g.choose_index(3)],
        Resource::Dns(_) => [
            ResourceType::Cidr,
            ResourceType::StaticDevicePool,
            ResourceType::DynamicDevicePool,
        ][g.choose_index(3)],
        Resource::StaticDevicePool(_) => [
            ResourceType::Cidr,
            ResourceType::Dns,
            ResourceType::DynamicDevicePool,
        ][g.choose_index(3)],
        Resource::DynamicDevicePool(_) => [
            ResourceType::Cidr,
            ResourceType::Dns,
            ResourceType::StaticDevicePool,
        ][g.choose_index(3)],
        Resource::Internet(_) => {
            unreachable!("the Portal API does not allow editing the Internet Resource")
        }
    };

    let site = resource
        .sites()
        .first()
        .cloned()
        .unwrap_or_else(|| pick_site(g, state.regular_sites()).clone());
    let id = resource.id();
    let name = resource.name().to_owned();
    let filters = resource.filters().to_vec();

    match resource_type {
        ResourceType::Cidr => Resource::Cidr(CidrResource {
            id,
            address: arb_cidr_resource_address(g),
            name,
            address_description: arb_address_description(g),
            sites: vec![site],
            filters,
        }),
        ResourceType::Dns => {
            let base = arb_domain_name_string(g, 2, 3);
            let address = match g.choose_index(3) {
                0 => base,
                1 => format!("*.{base}"),
                _ => format!("**.{base}"),
            };

            Resource::Dns(DnsResource {
                id,
                address,
                name,
                address_description: arb_address_description(g),
                sites: vec![site],
                ip_stack: arb_ip_stack_kind(g),
                filters,
            })
        }
        ResourceType::StaticDevicePool => Resource::StaticDevicePool(StaticDevicePoolResource {
            id,
            name,
            devices: packets::arb_online_static_pool_members(g, state),
            filters,
        }),
        ResourceType::DynamicDevicePool => {
            let base = arb_domain_name_string(g, 2, 3);

            Resource::DynamicDevicePool(DynamicDevicePoolResource {
                id,
                name,
                address: format!("*.{base}"),
                filters,
            })
        }
    }
}

/// Reproduces `Union::new_weighted`: partition `int_in_range` over the summed
/// weight. Identical bytes always pick the same arm.
fn weighted_choose(g: &mut Generator, opts: &[(TransitionKind, u32)]) -> Option<TransitionKind> {
    if opts.is_empty() {
        return None;
    }
    let total = opts.iter().map(|(_, weight)| *weight).sum::<u32>();
    let pick = g.u32_in(0..=total - 1);

    opts.iter()
        .scan(0, |end, (kind, weight)| {
            *end += *weight;
            Some((*kind, *end))
        })
        .find_map(|(kind, end)| (pick < end).then_some(kind))
}

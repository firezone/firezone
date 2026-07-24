use std::{
    collections::BTreeMap,
    time::{Duration, Instant},
};

use connlib_model::Site;
use dns_types::DomainName;

use super::context::Generator;
use super::topology::{
    arb_dns_record_set, arb_relays, arb_socket_ip_stack, pick_site, with_interface,
};
use super::values::{
    arb_address_description, arb_cidr_resource_address, arb_compatible_upstream_do53_servers,
    arb_different_cidr_resource_address, arb_different_filters, arb_domain_name_string,
    arb_ip_stack_kind, arb_system_dns_servers, arb_upstream_doh_servers,
};
use super::{dns_queries, packets};
use crate::reference::ReferenceState;
use crate::resource::{CidrResource, DnsResource, Resource, StaticDevicePoolResource};
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
    PartitionRelaysFromPortal,
    RebootRelaysWhilePartitioned,
    Idle,
    // State-gated.
    AddResource,
    ChangeCidrResourceAddress,
    MoveResourceToNewSite,
    ChangeFiltersOfResource,
    ChangeResourceType,
    RemoveResource,
    ReconnectPortal,
    RestartClient,
    SetInternetResourceState,
    DeauthorizeWhileGatewayIsPartitioned,
    UpdateDnsRecords,
    SendPacket,
    SendDnsQuery,
    // Static device pool membership update.
    UpdateStaticDevicePool,
}

fn move_resource_candidates(state: &ReferenceState) -> Vec<(Resource, Site)> {
    let sites = state.regular_sites();

    state
        .cidr_and_dns_resources_on_any_client()
        .into_iter()
        .flat_map(|resource| {
            let candidate = resource.clone();
            sites
                .iter()
                .filter(move |site| !candidate.is_exclusively_at(site))
                .map(move |site| (resource.clone(), site.clone()))
        })
        .collect::<Vec<_>>()
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
    }

    let resource_type = match resource {
        Resource::Cidr(_) => [ResourceType::Dns, ResourceType::StaticDevicePool][g.choose_index(2)],
        Resource::Dns(_) => [ResourceType::Cidr, ResourceType::StaticDevicePool][g.choose_index(2)],
        Resource::StaticDevicePool(_) => [ResourceType::Cidr, ResourceType::Dns][g.choose_index(2)],
        Resource::Internet(_) | Resource::DynamicDevicePool(_) => {
            unreachable!("only user-editable resource types can replace one another")
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
    }
}

pub(super) fn generate(
    g: &mut Generator,
    state: &ReferenceState,
    now: Instant,
) -> Option<Transition> {
    let addable_resources = state.resources_unknown_to_all_clients();
    let cidr_resources = state.cidr_resources_on_any_client();
    let move_resources = move_resource_candidates(state);
    let filter_resources = state.resources_with_filters_on_any_client();
    let replaceable_resources = state.replaceable_resources_on_any_client();
    let removable_resources = state.removable_resource_ids();
    let deauthorizable_resources = state.deauthorizable_resource_ids();
    let client_ids = state.all_client_ids();
    let dns_record_domains = state.dns_resource_domains();
    let packet_targets = packets::targets(state, now);
    let dns_query_targets = dns_queries::targets(state, now);
    let static_device_pools = state.static_device_pools_on_any_client();

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
        Some((K::PartitionRelaysFromPortal, 1)),
        Some((K::RebootRelaysWhilePartitioned, 1)),
        Some((K::Idle, 1)),
        (!addable_resources.is_empty()).then_some((K::AddResource, 5)),
        (!cidr_resources.is_empty()).then_some((K::ChangeCidrResourceAddress, 1)),
        (!move_resources.is_empty()).then_some((K::MoveResourceToNewSite, 1)),
        (!filter_resources.is_empty()).then_some((K::ChangeFiltersOfResource, 1)),
        (!replaceable_resources.is_empty()).then_some((K::ChangeResourceType, 2)),
        (!removable_resources.is_empty()).then_some((K::RemoveResource, 1)),
        (!deauthorizable_resources.is_empty())
            .then_some((K::DeauthorizeWhileGatewayIsPartitioned, 1)),
        (!client_ids.is_empty()).then_some((K::ReconnectPortal, 1)),
        (!client_ids.is_empty()).then_some((K::RestartClient, 1)),
        (!client_ids.is_empty()).then_some((K::SetInternetResourceState, 1)),
        (!dns_record_domains.is_empty()).then_some((K::UpdateDnsRecords, 5)),
        (!packet_targets.is_empty()).then_some((K::SendPacket, 50)),
        (!dns_query_targets.is_empty()).then_some((K::SendDnsQuery, 10)),
        (!static_device_pools.is_empty()).then_some((K::UpdateStaticDevicePool, 2)),
    ]
    .into_iter()
    .flatten()
    .collect::<Vec<_>>();

    // 2. Weighted pick over the legal list.
    let kind = weighted_choose(g, &legal)?;

    // 3. Generate the chosen arm's payload from the following bytes.
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
            let ids = state.all_client_ids();
            let client_id = ids[g.choose_index(ids.len())];
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
        K::PartitionRelaysFromPortal => Transition::PartitionRelaysFromPortal,
        K::RebootRelaysWhilePartitioned => {
            // Reboot the *existing* relays with fresh credentials (same ids).
            let ids = state.relays.keys().copied().collect::<Vec<_>>();
            let relays = ids
                .into_iter()
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
        K::Idle => Transition::Idle,
        K::AddResource => {
            let resource = addable_resources[g.choose_index(addable_resources.len())].clone();
            Transition::AddResource(resource)
        }
        K::ChangeCidrResourceAddress => {
            let resource = cidr_resources[g.choose_index(cidr_resources.len())].clone();
            let new_address = arb_different_cidr_resource_address(g, resource.address);
            Transition::ChangeCidrResourceAddress {
                resource,
                new_address,
            }
        }
        K::MoveResourceToNewSite => {
            let (resource, new_site) = move_resources[g.choose_index(move_resources.len())].clone();
            Transition::MoveResourceToNewSite { resource, new_site }
        }
        K::ChangeFiltersOfResource => {
            let resource = filter_resources[g.choose_index(filter_resources.len())].clone();
            let new_filters = arb_different_filters(g, resource.filters());
            Transition::ChangeFiltersOfResource {
                resource,
                new_filters,
            }
        }
        K::ChangeResourceType => {
            let old_resource =
                replaceable_resources[g.choose_index(replaceable_resources.len())].clone();
            let new_resource = arb_resource_with_different_type(g, state, &old_resource);
            Transition::ChangeResourceType {
                old_resource,
                new_resource,
            }
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
            packets::generate(g, state, target)
        }
        K::SendDnsQuery => {
            let target = dns_query_targets[g.choose_index(dns_query_targets.len())].clone();
            dns_queries::generate(g, target)
        }
        K::UpdateStaticDevicePool => {
            let pool = static_device_pools[g.choose_index(static_device_pools.len())].clone();
            Transition::UpdateStaticDevicePool {
                pool_id: pool.id,
                new_devices: packets::arb_static_pool_members(g, state, &pool),
            }
        }
    };

    Some(transition)
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

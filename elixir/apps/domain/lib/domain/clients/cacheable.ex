defprotocol Domain.Clients.Cacheable do
  @doc "Converts a Domain struct to its cache representation."
  def to_cache(struct)
end

defimpl Domain.Clients.Cacheable, for: Domain.Gateways.Group do
  def to_cache(%Domain.Gateways.Group{} = gateway_group) do
    %Domain.Clients.Cache.GatewayGroup{
      id: Ecto.UUID.dump!(gateway_group.id),
      name: gateway_group.name
    }
  end
end

defimpl Domain.Clients.Cacheable, for: Domain.Resources.Resource do
  def to_cache(%Domain.Resources.Resource{} = resource) do
    %Domain.Clients.Cache.Resource{
      id: Ecto.UUID.dump!(resource.id),
      type: resource.type,
      name: resource.name,
      address: resource.address,
      address_description: resource.address_description,
      ip_stack: resource.ip_stack,
      filters: Enum.map(resource.filters, &Map.from_struct/1),
      gateway_groups: Enum.map(resource.gateway_groups, &Domain.Clients.Cacheable.to_cache/1)
    }
  end
end

defimpl Domain.Clients.Cacheable, for: Domain.Policies.Policy do
  def to_cache(%Domain.Policies.Policy{} = policy) do
    %Domain.Clients.Cache.Policy{
      id: Ecto.UUID.dump!(policy.id),
      resource_id: Ecto.UUID.dump!(policy.resource_id),
      actor_group_id: Ecto.UUID.dump!(policy.actor_group_id),
      conditions: Enum.map(policy.conditions, &Map.from_struct/1)
    }
  end
end

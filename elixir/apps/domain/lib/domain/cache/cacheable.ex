defprotocol Domain.Cache.Cacheable do
  @type uuid_binary :: <<_::128>>

  @doc "Converts a Domain struct to its cache representation."
  def to_cache(struct)
end

defimpl Domain.Cache.Cacheable, for: Domain.Gateways.Group do
  def to_cache(%Domain.Gateways.Group{} = gateway_group) do
    %Domain.Cache.Cacheable.GatewayGroup{
      id: Ecto.UUID.dump!(gateway_group.id),
      name: gateway_group.name
    }
  end
end

defimpl Domain.Cache.Cacheable, for: Domain.Resource do
  def to_cache(%Domain.Resource{} = resource) do
    %Domain.Cache.Cacheable.Resource{
      id: Ecto.UUID.dump!(resource.id),
      type: resource.type,
      name: resource.name,
      address: resource.address,
      address_description: resource.address_description,
      ip_stack: resource.ip_stack,
      filters: Enum.map(resource.filters, &Map.from_struct/1),
      gateway_groups:
        if(is_list(resource.gateway_groups),
          do: Enum.map(resource.gateway_groups, &Domain.Cache.Cacheable.to_cache/1),
          else: []
        )
    }
  end
end

defimpl Domain.Cache.Cacheable, for: Domain.Policies.Policy do
  def to_cache(%Domain.Policies.Policy{} = policy) do
    %Domain.Cache.Cacheable.Policy{
      id: Ecto.UUID.dump!(policy.id),
      resource_id: Ecto.UUID.dump!(policy.resource_id),
      actor_group_id: Ecto.UUID.dump!(policy.actor_group_id),
      conditions: Enum.map(policy.conditions, &Map.from_struct/1)
    }
  end
end

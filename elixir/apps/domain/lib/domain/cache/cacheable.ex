defprotocol Domain.Cache.Cacheable do
  @type uuid_binary :: <<_::128>>

  @doc "Converts a Domain struct to its cache representation."
  def to_cache(struct)
end

defimpl Domain.Cache.Cacheable, for: Domain.Site do
  def to_cache(nil), do: nil

  def to_cache(%Domain.Site{} = site) do
    %Domain.Cache.Cacheable.Site{
      id: Ecto.UUID.dump!(site.id),
      name: site.name
    }
  end
end

defimpl Domain.Cache.Cacheable, for: Domain.Resource do
  def to_cache(%Domain.Resource{} = resource) do
    site =
      if is_struct(resource.site, Domain.Site) do
        Domain.Cache.Cacheable.to_cache(resource.site)
      else
        nil
      end

    %Domain.Cache.Cacheable.Resource{
      id: Ecto.UUID.dump!(resource.id),
      type: resource.type,
      name: resource.name,
      address: resource.address,
      address_description: resource.address_description,
      ip_stack: resource.ip_stack,
      filters: Enum.map(resource.filters, &Map.from_struct/1),
      site: site
    }
  end
end

defimpl Domain.Cache.Cacheable, for: Domain.Policy do
  def to_cache(%Domain.Policy{} = policy) do
    %Domain.Cache.Cacheable.Policy{
      id: Ecto.UUID.dump!(policy.id),
      resource_id: Ecto.UUID.dump!(policy.resource_id),
      group_id: Ecto.UUID.dump!(policy.group_id),
      conditions: Enum.map(policy.conditions, &Map.from_struct/1)
    }
  end
end

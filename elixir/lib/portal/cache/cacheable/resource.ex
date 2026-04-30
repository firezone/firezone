defmodule Portal.Cache.Cacheable.Resource do
  defstruct [
    :id,
    :name,
    :type,
    :address,
    :address_description,
    :ip_stack,
    :filters,
    :devices,
    :site
  ]

  @type filter :: %{
          protocol: :tcp | :udp | :icmp,
          ports: [String.t()]
        }

  @type pool_device :: %{
          id: Ecto.UUID.t(),
          ipv4: Postgrex.INET.t(),
          ipv6: Postgrex.INET.t()
        }

  @type t :: %__MODULE__{
          id: Portal.Cache.Cacheable.uuid_binary(),
          name: String.t(),
          type: :cidr | :ip | :dns | :internet | :static_device_pool,
          address: String.t(),
          address_description: String.t(),
          ip_stack: atom(),
          filters: [filter()],
          devices: [pool_device()] | nil,
          site: Portal.Cache.Cacheable.Site.t() | nil
        }
end

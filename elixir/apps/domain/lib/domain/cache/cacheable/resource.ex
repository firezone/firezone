defmodule Domain.Cache.Cacheable.Resource do
  defstruct [
    :id,
    :name,
    :type,
    :address,
    :address_description,
    :ip_stack,
    :filters,
    :gateway_groups
  ]

  @type filter :: %{
          protocol: :tcp | :udp | :icmp,
          ports: [String.t()]
        }

  @type t :: %__MODULE__{
          id: Domain.Cache.Cacheable.uuid_binary(),
          name: String.t(),
          type: :cidr | :ip | :dns | :internet,
          address: String.t(),
          address_description: String.t(),
          ip_stack: atom(),
          filters: [filter()],
          gateway_groups: [Domain.Cache.Cacheable.GatewayGroup.t()]
        }
end

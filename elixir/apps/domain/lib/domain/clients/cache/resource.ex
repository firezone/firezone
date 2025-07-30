defmodule Domain.Clients.Cache.Resource do
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
          ports: [Domain.Types.Int4Range.t()]
        }

  @type t :: %__MODULE__{
          id: Domain.Clients.Cache.uuid_binary(),
          name: String.t(),
          type: :cidr | :ip | :dns | :internet,
          address: String.t(),
          address_description: String.t(),
          ip_stack: atom(),
          filters: [filter()],
          gateway_groups: [GatewayGroup.t()]
        }
end

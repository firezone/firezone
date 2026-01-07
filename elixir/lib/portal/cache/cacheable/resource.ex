defmodule Portal.Cache.Cacheable.Resource do
  defstruct [
    :id,
    :name,
    :type,
    :address,
    :address_description,
    :ip_stack,
    :filters,
    :site
  ]

  @type filter :: %{
          protocol: :tcp | :udp | :icmp,
          ports: [String.t()]
        }

  @type t :: %__MODULE__{
          id: Portal.Cache.Cacheable.uuid_binary(),
          name: String.t(),
          type: :cidr | :ip | :dns | :internet,
          address: String.t(),
          address_description: String.t(),
          ip_stack: atom(),
          filters: [filter()],
          site: Portal.Cache.Cacheable.Site.t() | nil
        }
end

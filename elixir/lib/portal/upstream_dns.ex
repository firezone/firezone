defmodule Portal.UpstreamDNS do
  use Ecto.Schema
  import Ecto.Changeset
  import Portal.Changeset
  alias Portal.Types.IPPort

  @type t :: %__MODULE__{
          type: :system | :secure | :custom,
          doh_provider: :google | :opendns | :cloudflare | :quad9,
          addresses: [%__MODULE__.Address{address: String.t()}]
        }

  @primary_key false
  embedded_schema do
    field :type, Ecto.Enum, values: [:system, :secure, :custom], default: :system

    field :doh_provider, Ecto.Enum,
      values: [:google, :opendns, :cloudflare, :quad9],
      default: :google

    embeds_many :addresses, Address,
      primary_key: false,
      on_replace: :delete do
      field :address, :string
    end
  end

  def changeset(schema, attrs) do
    schema
    |> cast(attrs, [:type, :doh_provider])
    |> cast_embed(:addresses,
      with: &address_changeset/2,
      sort_param: :addresses_sort,
      drop_param: :addresses_drop
    )
    |> validate_length(:addresses, max: 8, message: "cannot exceed 8 resolvers")
    |> validate_doh_provider_for_secure()
    |> validate_addresses_for_type()
    |> validate_custom_has_addresses()
  end

  defp address_changeset(schema, attrs) do
    schema
    |> cast(attrs, [:address])
    |> validate_required([:address])
    |> trim_change(:address)
    |> validate_ip_address()
    |> validate_reserved_ip_exclusion()
  end

  defp validate_ip_address(changeset) do
    validate_change(changeset, :address, fn :address, address ->
      case IPPort.cast(address) do
        {:ok, %IPPort{port: nil}} -> []
        {:ok, %IPPort{}} -> [address: "must not include a port"]
        _ -> [address: "must be a valid IP address"]
      end
    end)
  end

  defp validate_doh_provider_for_secure(changeset) do
    with true <- changeset.valid?,
         {_data_or_changes, type} <- fetch_field(changeset, :type),
         {_data_or_changes, doh_provider} <- fetch_field(changeset, :doh_provider) do
      if type == :secure and is_nil(doh_provider) do
        add_error(changeset, :doh_provider, "must be selected when using secure DNS")
      else
        changeset
      end
    else
      _ -> changeset
    end
  end

  defp validate_addresses_for_type(changeset) do
    with true <- changeset.valid?,
         {_data_or_changes, type} <- fetch_field(changeset, :type),
         {_data_or_changes, addresses} <- fetch_field(changeset, :addresses) do
      case type do
        :custom ->
          validate_custom_addresses(changeset, addresses)

        _ ->
          # For system and secure DNS, addresses are ignored but not cleared
          # This allows users to switch between types without losing their custom addresses
          changeset
      end
    else
      _ -> changeset
    end
  end

  defp validate_custom_addresses(changeset, addresses) do
    # Check for unique addresses
    normalized_addresses =
      addresses
      |> Enum.map(&normalize_dns_address/1)
      |> Enum.reject(&is_nil/1)

    if normalized_addresses -- Enum.uniq(normalized_addresses) == [] do
      changeset
    else
      add_error(changeset, :addresses, "all addresses must be unique")
    end
  end

  defp validate_custom_has_addresses(changeset) do
    with true <- changeset.valid?,
         {_data_or_changes, type} <- fetch_field(changeset, :type),
         {_data_or_changes, addresses} <- fetch_field(changeset, :addresses) do
      if type == :custom and Enum.empty?(addresses) do
        add_error(changeset, :addresses, "must have at least one custom resolver")
      else
        changeset
      end
    else
      _ -> changeset
    end
  end

  defp validate_reserved_ip_exclusion(changeset) do
    if has_errors?(changeset, :address) do
      changeset
    else
      changeset
      |> validate_not_in_cidr(:address, Portal.Device.reserved_ipv4_cidr())
      |> validate_not_in_cidr(:address, Portal.Device.reserved_ipv6_cidr())
    end
  end

  defp normalize_dns_address(%__MODULE__.Address{address: address}) do
    address
  end

  defp normalize_dns_address(_), do: nil
end

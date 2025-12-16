defmodule Domain.Accounts.Config do
  use Ecto.Schema
  import Ecto.Changeset
  import Domain.Changeset
  alias Domain.Types.IPPort
  alias Domain.Accounts.Config

  @primary_key false
  embedded_schema do
    field :search_domain, :string

    embeds_one :clients_upstream_dns, ClientsUpstreamDns,
      primary_key: false,
      on_replace: :update do
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

    embeds_one :notifications, Notifications,
      primary_key: false,
      on_replace: :update do
      embeds_one :outdated_gateway, Domain.Accounts.Config.Notifications.Email,
        on_replace: :update
    end
  end

  @doc """
  Returns a default config with defaults set
  """
  def default_config do
    %__MODULE__{
      clients_upstream_dns: %__MODULE__.ClientsUpstreamDns{
        type: :system
      },
      notifications: %__MODULE__.Notifications{
        outdated_gateway: %Domain.Accounts.Config.Notifications.Email{enabled: true}
      }
    }
  end

  @doc """
  Ensures a config has proper defaults
  """
  def ensure_defaults(%__MODULE__{} = config) do
    # Ensure notifications defaults
    notifications = config.notifications || %__MODULE__.Notifications{}

    outdated_gateway =
      notifications.outdated_gateway || %Domain.Accounts.Config.Notifications.Email{enabled: true}

    outdated_gateway =
      case outdated_gateway.enabled do
        nil -> %{outdated_gateway | enabled: true}
        _ -> outdated_gateway
      end

    notifications = %{notifications | outdated_gateway: outdated_gateway}

    %{config | notifications: notifications}
  end

  def ensure_defaults(nil), do: default_config()

  @doc """
  Changeset function for embedded Config
  """
  def changeset(config \\ %__MODULE__{}, attrs) do
    config
    |> cast(attrs, [:search_domain])
    |> cast_embed(:clients_upstream_dns, with: &clients_upstream_dns_changeset/2)
    |> cast_embed(:notifications, with: &notifications_changeset/2)
    |> validate_search_domain()
  end

  defp clients_upstream_dns_changeset(schema, attrs) do
    schema
    |> cast(attrs, [:type, :doh_provider])
    |> cast_embed(:addresses,
      with: &address_changeset/2,
      sort_param: :addresses_sort,
      drop_param: :addresses_drop
    )
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

  defp notifications_changeset(schema, attrs) do
    schema
    |> cast(attrs, [])
    |> cast_embed(:outdated_gateway, with: &email_changeset/2)
  end

  defp email_changeset(schema, attrs) do
    schema
    |> cast(attrs, [:enabled])
  end

  defp validate_search_domain(changeset) do
    changeset
    |> validate_change(:search_domain, fn :search_domain, domain ->
      cond do
        domain == nil || domain == "" ->
          [search_domain: "cannot be empty"]

        String.length(domain) > 255 ->
          [search_domain: "must not exceed 255 characters"]

        String.starts_with?(domain, ".") ->
          [search_domain: "must not start with a dot"]

        String.contains?(domain, "..") ->
          [search_domain: "must not contain consecutive dots"]

        !String.match?(domain, ~r/^[a-z0-9][a-z0-9.-]*\.[a-z]{2,}$/i) ->
          [search_domain: "must be a valid fully-qualified domain name"]

        Enum.any?(String.split(domain, "."), &(String.length(&1) > 63)) ->
          [search_domain: "each label must not exceed 63 characters"]

        true ->
          []
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
      |> validate_not_in_cidr(:address, Domain.IPv4Address.reserved_cidr())
      |> validate_not_in_cidr(:address, Domain.IPv6Address.reserved_cidr())
    end
  end

  defp normalize_dns_address(%Config.ClientsUpstreamDns.Address{address: address}) do
    address
  end

  defp normalize_dns_address(_), do: nil
end

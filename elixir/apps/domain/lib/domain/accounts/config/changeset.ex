defmodule Domain.Accounts.Config.Changeset do
  import Ecto.Changeset
  import Domain.Changeset
  alias Domain.Types.IPPort
  alias Domain.Accounts.Config

  def changeset(config \\ %Config{}, attrs) do
    config
    |> cast(attrs, [:search_domain])
    |> cast_embed(:clients_upstream_dns, with: &clients_upstream_dns_changeset/2)
    |> cast_embed(:notifications, with: &notifications_changeset/2)
    |> validate_search_domain()
  end

  def clients_upstream_dns_changeset(clients_upstream_dns \\ %Config.ClientsUpstreamDns{}, attrs) do
    clients_upstream_dns
    |> cast(attrs, [:type, :doh_provider])
    |> validate_required([:type])
    |> cast_embed(:addresses,
      with: &address_changeset/2,
      sort_param: :addresses_sort,
      drop_param: :addresses_drop
    )
    |> validate_doh_provider_for_secure()
    |> validate_addresses_for_type()
    |> validate_custom_has_addresses()
  end

  def address_changeset(address \\ %Config.ClientsUpstreamDns.Address{}, attrs) do
    address
    |> cast(attrs, [:address])
    |> validate_required([:address])
    |> trim_change(:address)
    |> validate_ip_address()
    |> validate_reserved_ip_exclusion()
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

  defp validate_ip_address(changeset) do
    validate_change(changeset, :address, fn :address, address ->
      case IPPort.cast(address) do
        {:ok, %IPPort{port: nil}} -> []
        {:ok, %IPPort{}} -> [address: "must not include a port"]
        _ -> [address: "must be a valid IP address"]
      end
    end)
  end

  defp validate_reserved_ip_exclusion(changeset) do
    if has_errors?(changeset, :address) do
      changeset
    else
      Domain.Network.reserved_cidrs()
      |> Enum.reduce(changeset, fn {_type, cidr}, changeset ->
        validate_not_in_cidr(changeset, :address, cidr)
      end)
    end
  end

  def notifications_changeset(notifications, attrs) do
    notifications
    |> cast(attrs, [])
    |> cast_embed(:outdated_gateway, with: &Config.Notifications.Email.Changeset.changeset/2)
    |> cast_embed(:idp_sync_error, with: &Config.Notifications.Email.Changeset.changeset/2)
  end

  defp normalize_dns_address(%Config.ClientsUpstreamDns.Address{address: address}) do
    address
  end

  defp normalize_dns_address(_), do: nil
end

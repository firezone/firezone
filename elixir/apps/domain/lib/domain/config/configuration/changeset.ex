defmodule Domain.Config.Configuration.Changeset do
  use Domain, :changeset
  import Domain.Config, only: [config_changeset: 2]

  @fields ~w[clients_upstream_dns logo]a

  def changeset(configuration, attrs) do
    changeset =
      configuration
      |> cast(attrs, [])
      |> cast_embed(:logo)
      |> cast_embed(
        :clients_upstream_dns,
        with: &clients_upstream_dns_changeset/2
      )
      |> validate_unique_dns()

    Enum.reduce(@fields, changeset, fn field, changeset ->
      config_changeset(changeset, field)
    end)
    |> ensure_no_overridden_changes(configuration.account_id)
  end

  def clients_upstream_dns_changeset(
        dns_config \\ %Domain.Config.Configuration.ClientsUpstreamDNS{},
        attrs
      ) do
    Ecto.Changeset.cast(dns_config, attrs, [:type, :address])
    |> validate_required([:type, :address])
    |> trim_change(:address)
    |> validate_address()
  end

  defp validate_address(changeset) do
    {_origin, type} = fetch_field(changeset, :type)

    validate_change(changeset, :address, fn :address, address ->
      case type do
        "ip" ->
          case Domain.Types.IPPort.cast(address) do
            {:ok, _ip} ->
              []

            {:error, _reason} ->
              [address: "must be a valid IP address"]
          end

        "dns_over_tls" ->
          [address: "DNS over TLS is not supported yet"]

        "dns_over_http" ->
          [address: "DNS over HTTP is not supported yet"]

        _other ->
          [address: "Invalid Type"]
      end
    end)
  end

  defp normalize_dns_address(address) do
    case Domain.Types.IPPort.cast(address) do
      {:ok, ip} ->
        port = ip.port || 53
        %{ip | port: port} |> to_string()

      {:error, _reason} ->
        address

      :error ->
        address
    end
  end

  defp validate_unique_dns(changeset) do
    duplicates =
      apply_changes(changeset)
      |> Map.get(:clients_upstream_dns)
      |> Enum.map(fn dns ->
        normalize_dns_address(dns.address)
      end)
      |> Enum.reject(&is_nil/1)
      |> Enum.group_by(& &1)
      |> Enum.filter(fn {_, values} -> length(values) > 1 end)
      |> Enum.map(fn {key, _} -> key end)

    if length(duplicates) > 0 do
      add_error(changeset, :clients_upstream_dns, "no duplicates allowed")
    else
      changeset
    end
  end

  defp ensure_no_overridden_changes(changeset, account_id) do
    changed_keys = Map.keys(changeset.changes)

    configs =
      Domain.Config.fetch_resolved_configs_with_sources!(account_id, changed_keys,
        ignore_sources: :db
      )

    Enum.reduce(changed_keys, changeset, fn key, changeset ->
      case Map.fetch!(configs, key) do
        {{:env, source_key}, _value} ->
          add_error(
            changeset,
            key,
            "cannot be changed; " <>
              "it is overridden by #{source_key} environment variable"
          )

        _other ->
          changeset
      end
    end)
  end
end

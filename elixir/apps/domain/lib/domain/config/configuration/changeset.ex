defmodule Domain.Config.Configuration.Changeset do
  use Domain, :changeset
  import Domain.Config, only: [config_changeset: 2]
  alias Domain.Config.Configuration.ClientsUpstreamDNS

  @fields ~w[clients_upstream_dns logo]a

  def changeset(configuration, attrs) do
    changeset =
      configuration
      |> cast(attrs, [])
      |> cast_embed(:logo)
      |> cast_embed(:clients_upstream_dns)
      |> validate_unique_dns()

    Enum.reduce(@fields, changeset, fn field, changeset ->
      config_changeset(changeset, field)
    end)
    |> ensure_no_overridden_changes(configuration.account_id)
  end

  defp validate_unique_dns(changeset) do
    dns_addrs =
      apply_changes(changeset)
      |> Map.get(:clients_upstream_dns)
      |> Enum.map(&ClientsUpstreamDNS.normalize_dns_address/1)
      |> Enum.reject(&is_nil/1)

    duplicates = dns_addrs -- Enum.uniq(dns_addrs)

    if duplicates != [] do
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

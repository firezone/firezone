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

    Enum.reduce(@fields, changeset, fn field, changeset ->
      config_changeset(changeset, field)
    end)
    |> ensure_no_overridden_changes(configuration.account_id)
  end

  def clients_upstream_dns_changeset(
        dns_config \\ %Domain.Config.Configuration.ClientsUpstreamDNS{},
        attrs
      ) do
    Ecto.Changeset.cast(
      dns_config,
      attrs,
      [:address]
    )
    |> validate_required(:address)
    |> trim_change(:address)
    |> Domain.Validator.validate_one_of(:address, [
      &Domain.Validator.validate_fqdn/2,
      &Domain.Validator.validate_uri(&1, &2, schemes: ["https"])
    ])
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

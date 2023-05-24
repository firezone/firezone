defmodule Domain.Config.Configuration.Changeset do
  use Domain, :changeset
  import Domain.Config, only: [config_changeset: 2]

  @fields ~w[devices_upstream_dns]a

  def changeset(configuration, attrs) do
    changeset =
      configuration
      |> cast(attrs, @fields)
      |> cast_embed(:logo)
      |> trim_change(:devices_upstream_dns)

    Enum.reduce(@fields, changeset, fn field, changeset ->
      config_changeset(changeset, field)
    end)
    |> ensure_no_overridden_changes(configuration.account_id)
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

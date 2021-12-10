defmodule FzHttp.Settings.Setting do
  @moduledoc """
  Represents Firezone runtime configuration settings.

  Each record in the table has a unique key corresponding to a configuration setting.

  Settings values can be changed at application runtime on the fly.
  Settings cannot be created or destroyed by the running application.

  Settings are created / destroyed in migrations.
  """

  use Ecto.Schema
  import Ecto.Changeset

  import FzHttp.SharedValidators,
    only: [
      validate_list_of_ips: 2,
      validate_list_of_ips_or_cidrs: 2,
      validate_no_duplicates: 2
    ]

  schema "settings" do
    field :key, :string
    field :value, :string

    timestamps(type: :utc_datetime_usec)
  end

  @doc false
  def changeset(setting, attrs) do
    setting
    |> cast(attrs, [:key, :value])
    |> validate_required([:key])
    |> validate_setting()
  end

  defp validate_setting(%{data: %{key: key}, changes: %{value: _value}} = changeset) do
    changeset
    |> validate_kv_pair(key)
  end

  defp validate_setting(changeset), do: changeset

  defp validate_kv_pair(changeset, "default.device.dns_servers") do
    changeset
    |> validate_list_of_ips(:value)
    |> validate_no_duplicates(:value)
  end

  defp validate_kv_pair(changeset, "default.device.allowed_ips") do
    changeset
    |> validate_required(:value)
    |> validate_list_of_ips_or_cidrs(:value)
    |> validate_no_duplicates(:value)
  end

  defp validate_kv_pair(changeset, "default.device.endpoint") do
    changeset
    |> validate_list_of_ips_or_cidrs(:value)
    |> validate_no_duplicates(:value)
  end

  defp validate_kv_pair(changeset, unknown_key) do
    validate_change(changeset, :key, fn _current_field, _value ->
      [{:key, "is invalid: #{unknown_key} is not a valid setting"}]
    end)
  end
end

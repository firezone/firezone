defmodule FzHttp.Configurations.Mailer do
  @moduledoc """
  A non-persisted schema to validate email configs on boot.
  XXX: Consider persisting this to make outbound email configurable via API.
  """

  defstruct [:from, :provider, :configs]
  @types %{from: :string, provider: :string, configs: :map}

  def changeset(attrs) do
    {%__MODULE__{}, @types}
    |> Ecto.Changeset.cast(attrs, Map.keys(@types))
    |> Ecto.Changeset.validate_required([:from, :provider, :configs])
    |> Ecto.Changeset.validate_format(:from, ~r/@/)
    |> validate_provider_in_configs()
  end

  defp validate_provider_in_configs(
         %Ecto.Changeset{
           changes: %{provider: provider, configs: configs}
         } = changeset
       )
       when not is_map_key(configs, provider) do
    changeset
    |> Ecto.Changeset.add_error(:provider, "must exist in configs")
  end

  defp validate_provider_in_configs(changeset), do: changeset
end

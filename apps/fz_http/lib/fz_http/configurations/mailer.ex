defmodule FzHttp.Configurations.Mailer do
  @moduledoc """
  A non-persisted schema to validate email configs on boot.
  XXX: Consider persisting this to make outbound email configurable via API.
  """
  use Ecto.Schema
  import Ecto.Changeset

  embedded_schema do
    field :from, :string
    field :provider, :string
    field :configs, :map
  end

  def changeset(attrs) do
    %__MODULE__{}
    |> cast(attrs, [:from, :provider, :configs])
    |> validate_required([:from, :provider, :configs])
    |> validate_format(:from, ~r/@/)
    |> validate_provider_in_configs()
  end

  defp validate_provider_in_configs(
         %Ecto.Changeset{
           changes: %{provider: provider, configs: configs}
         } = changeset
       )
       when not is_map_key(configs, provider) do
    changeset
    |> add_error(:provider, "must exist in configs")
  end

  defp validate_provider_in_configs(changeset), do: changeset
end

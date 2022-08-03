defmodule FzHttp.Rules.RuleSetting do
  @moduledoc """
  Rule setting parsed from either a Rule struct or map.
  """
  use Ecto.Schema

  import Ecto.Changeset
  import FzHttp.Devices, only: [decode: 1]

  @primary_key false
  embedded_schema do
    field :action, Ecto.Enum, values: [:drop, :accept]
    field :destination, :string
    field :user_id, :integer
  end

  def parse(rule) when is_struct(rule) do
    %__MODULE__{
      destination: decode(rule.destination),
      action: rule.action,
      user_id: rule.user_id
    }
  end

  def parse(rule) when is_map(rule) do
    %__MODULE__{}
    |> cast(rule, [:action, :destination, :user_id])
    |> apply_changes()
  end
end

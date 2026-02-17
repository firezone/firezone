defmodule Portal.Actor.Preferences do
  use Ecto.Schema
  import Ecto.Changeset

  @start_page_values [:sites, :resources, :groups, :policies, :clients, :actors]

  @primary_key false
  embedded_schema do
    field :start_page, Ecto.Enum, values: @start_page_values, default: :sites
  end

  @spec start_page_values() :: [atom()]
  def start_page_values, do: @start_page_values

  @spec changeset(struct() | nil, map()) :: Ecto.Changeset.t()
  def changeset(preferences \\ %__MODULE__{}, attrs) do
    (preferences || %__MODULE__{})
    |> cast(attrs, [:start_page])
    |> validate_inclusion(:start_page, @start_page_values)
  end
end

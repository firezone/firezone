defmodule Portal.Actor.Preferences do
  use Ecto.Schema
  import Ecto.Changeset

  @start_page_values [:sites, :resources, :groups, :policies, :devices, :actors]

  # Where the actor is with the getting started guide:
  #
  #   * `nil`: never offered it, as for every actor that existed before it
  #   * `:pending`: sign up set it; the guide opens by itself
  #   * `:closed`: closed the guide before picking a goal; it stays in the sidebar
  #   * `:device_mesh` / `:remote_access`: the goal they picked
  #   * `:dismissed` / `:completed`: chose to explore alone, or finished; it's gone
  @getting_started_values [:pending, :closed, :device_mesh, :remote_access, :dismissed, :completed]

  @primary_key false
  embedded_schema do
    field :start_page, Ecto.Enum, values: @start_page_values, default: :sites
    field :getting_started, Ecto.Enum, values: @getting_started_values

    # What the "reach a remote network" guide created, so it can pick up where it
    # left off: the Resource, and the Gateway pre-created for its install command.
    field :getting_started_resource_id, :binary_id
    field :getting_started_gateway_id, :binary_id
  end

  @spec start_page_values() :: [atom()]
  def start_page_values, do: @start_page_values

  @spec changeset(struct() | nil, map()) :: Ecto.Changeset.t()
  def changeset(preferences \\ %__MODULE__{}, attrs) do
    (preferences || %__MODULE__{})
    |> cast(attrs, [:start_page])
    |> validate_inclusion(:start_page, @start_page_values)
  end

  @spec getting_started_changeset(struct() | nil, map()) :: Ecto.Changeset.t()
  def getting_started_changeset(preferences \\ %__MODULE__{}, attrs) do
    (preferences || %__MODULE__{})
    |> cast(attrs, [:getting_started, :getting_started_resource_id, :getting_started_gateway_id])
    |> validate_required([:getting_started])
  end
end

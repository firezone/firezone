defmodule Portal.MetricsDiagnostics do
  @moduledoc """
  Until `expires_at`, the actor's Clients export every metric at the shortest
  interval, labelled with the actor and device so they can be told apart.
  """
  use Ecto.Schema
  import Ecto.Changeset
  alias __MODULE__.Database

  @type t :: %__MODULE__{}

  @primary_key false
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  schema "metrics_diagnostics" do
    belongs_to :account, Portal.Account, primary_key: true
    belongs_to :actor, Portal.Actor, primary_key: true
    field :expires_at, :utc_datetime_usec

    timestamps()
  end

  def changeset(%Ecto.Changeset{} = changeset) do
    changeset
    |> validate_required([:account_id, :actor_id, :expires_at])
    |> assoc_constraint(:account)
    |> assoc_constraint(:actor)
  end

  @doc """
  Whether the actor of the Client `device` has unexpired diagnostics.
  """
  @spec active?(Portal.Device.t()) :: boolean()
  def active?(%Portal.Device{type: :client, actor_id: actor_id} = device) when is_binary(actor_id) do
    Database.active?(device.account_id, actor_id)
  end

  def active?(%Portal.Device{}), do: false

  defmodule Database do
    import Ecto.Query
    alias Portal.{MetricsDiagnostics, Safe}

    def active?(account_id, actor_id) do
      from(d in MetricsDiagnostics,
        where: d.account_id == ^account_id and d.actor_id == ^actor_id,
        where: d.expires_at > fragment("now()")
      )
      |> Safe.unscoped()
      |> Safe.exists?()
    end
  end
end

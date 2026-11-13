defmodule Portal.PlanMetrics do
  @moduledoc """
  Metric name patterns the Clients and Gateways of every account on `plan`
  export. `plan` is a `Portal.Billing.plan_type/1` value.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @plans ~w[enterprise business team starter unknown]

  @primary_key {:plan, :string, autogenerate: false}
  @timestamps_opts [type: :utc_datetime_usec]

  schema "plan_metrics" do
    field :patterns, {:array, :string}

    timestamps()
  end

  def changeset(%Ecto.Changeset{} = changeset) do
    changeset
    |> validate_required([:plan, :patterns])
    |> validate_inclusion(:plan, @plans)
    |> validate_length(:patterns, min: 1)
  end
end

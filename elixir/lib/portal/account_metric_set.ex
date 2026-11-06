defmodule Portal.AccountMetricSet do
  @moduledoc """
  Metric name patterns the account's Clients and Gateways export, on top of
  those of its plan.
  """
  use Ecto.Schema
  import Ecto.Changeset
  alias __MODULE__.Database

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  schema "account_metric_sets" do
    belongs_to :account, Portal.Account
    field :patterns, {:array, :string}
    field :description, :string

    timestamps()
  end

  def changeset(%Ecto.Changeset{} = changeset) do
    changeset
    |> validate_required([:patterns])
    |> validate_length(:patterns, min: 1)
    |> assoc_constraint(:account)
  end

  @doc """
  The sorted, de-duplicated union of the patterns of the account's plan and of
  the account itself.
  """
  @spec effective_patterns(Portal.Account.t()) :: [String.t()]
  def effective_patterns(%Portal.Account{} = account) do
    account
    |> Portal.Billing.plan_type()
    |> Atom.to_string()
    |> Database.list_patterns(account.id)
    |> Enum.sort()
  end

  defmodule Database do
    import Ecto.Query
    alias Portal.{AccountMetricSet, PlanMetricSet, Safe}

    def list_patterns(plan, account_id) do
      account_patterns =
        from(s in AccountMetricSet,
          where: s.account_id == ^account_id,
          select: fragment("unnest(?)", s.patterns)
        )

      from(s in PlanMetricSet, where: s.plan == ^plan, select: fragment("unnest(?)", s.patterns))
      |> union(^account_patterns)
      |> Safe.unscoped()
      |> Safe.all()
    end
  end
end

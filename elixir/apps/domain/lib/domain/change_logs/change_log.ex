defmodule Domain.ChangeLogs.ChangeLog do
  use Domain, :schema

  schema "change_logs" do
    belongs_to :account, Domain.Accounts.Account

    field :table, :string
    field :op, Ecto.Enum, values: [:insert, :update, :delete]
    field :old_data, :map
    field :data, :map
    field :vsn, :integer

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end
end

defmodule Domain.ChangeLog do
  use Domain, :schema

  @primary_key false
  schema "change_logs" do
    belongs_to :account, Domain.Account

    field :lsn, :integer, primary_key: true
    field :table, :string
    field :op, Ecto.Enum, values: [:insert, :update, :delete]
    field :old_data, :map
    field :data, :map
    field :subject, :map
    field :vsn, :integer

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end
end

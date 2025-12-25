defmodule Portal.ChangeLog do
  use Ecto.Schema

  @primary_key false
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  schema "change_logs" do
    belongs_to :account, Portal.Account

    field :lsn, :integer, primary_key: true
    field :table, :string
    field :op, Ecto.Enum, values: [:insert, :update, :delete]
    field :old_data, :map
    field :data, :map
    field :subject, :map
    field :vsn, :integer

    timestamps(updated_at: false)
  end
end

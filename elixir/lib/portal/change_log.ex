defmodule Portal.ChangeLog do
  # credo:disable-for-this-file Credo.Check.Warning.MissingChangesetFunction
  use Ecto.Schema

  @primary_key {:id, Ecto.UUID, autogenerate: false}
  @foreign_key_type :binary_id

  schema "change_logs" do
    # intentionally ommitted from pkey because id is a uuidv7
    # and we want to leverage its pkey index for efficient range queries
    belongs_to :account, Portal.Account

    field :lsn, :integer
    field :table, :string
    field :op, Ecto.Enum, values: [:insert, :update, :delete]
    field :old_data, :map
    field :data, :map
    field :subject, :map
    field :vsn, :integer
  end
end

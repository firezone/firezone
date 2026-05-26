defmodule Portal.ChangeLog do
  # credo:disable-for-this-file Credo.Check.Warning.MissingChangesetFunction
  use Ecto.Schema

  @primary_key false
  @foreign_key_type :binary_id

  schema "change_logs" do
    belongs_to :account, Portal.Account, primary_key: true
    field :id, Ecto.UUID, primary_key: true, autogenerate: false
    field :lsn, :integer
    field :table, :string
    field :op, Ecto.Enum, values: [:insert, :update, :delete]
    field :old_data, :map
    field :data, :map
    field :subject, :map
    field :vsn, :integer
  end
end

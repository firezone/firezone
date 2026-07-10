defmodule Portal.ChangeLog do
  # credo:disable-for-this-file Credo.Check.Warning.MissingChangesetFunction
  use Ecto.Schema

  @primary_key false
  @foreign_key_type :binary_id

  schema "change_logs" do
    belongs_to :account, Portal.Account, primary_key: true
    field :log_id, Portal.Types.LogId, primary_key: true
    field :timestamp, :utc_datetime_usec
    field :lsn, :integer
    field :object, :string
    field :operation, Ecto.Enum, values: [:insert, :update, :delete]
    field :before, :map
    field :after, :map
    field :subject, :map
    field :vsn, :integer
  end
end

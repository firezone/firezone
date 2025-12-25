defmodule Portal.Accounts.Config.Notifications.Email do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
  embedded_schema do
    field :enabled, :boolean, default: true
    field :last_notified, :utc_datetime
  end

  def changeset(config \\ %__MODULE__{}, attrs) do
    config
    |> cast(attrs, [:enabled, :last_notified])
  end
end

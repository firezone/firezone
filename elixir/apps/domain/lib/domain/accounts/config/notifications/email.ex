defmodule Domain.Accounts.Config.Notifications.Email do
  use Domain, :schema

  @primary_key false

  embedded_schema do
    field :enabled, :boolean
    field :last_notified, :utc_datetime
  end
end

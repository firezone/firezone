defmodule Domain.Accounts.Config.Notifications.Email do
  use Domain, :schema

  @primary_key false

  embedded_schema do
    field :enabled, :boolean, default: true
    field :last_notified, :utc_datetime
  end
end

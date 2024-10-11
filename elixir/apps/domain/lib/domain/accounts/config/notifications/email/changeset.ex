defmodule Domain.Accounts.Config.Notifications.Email.Changeset do
  use Domain, :changeset
  alias Domain.Accounts.Config.Notifications.Email

  def changeset(config \\ %Email{}, attrs) do
    config
    |> cast(attrs, [:enabled, :last_notified])
  end
end

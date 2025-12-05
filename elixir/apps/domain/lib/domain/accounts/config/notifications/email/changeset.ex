defmodule Domain.Accounts.Config.Notifications.Email.Changeset do
  import Ecto.Changeset
  alias Domain.Accounts.Config.Notifications.Email

  def changeset(config \\ %Email{}, attrs) do
    config
    |> cast(attrs, [:enabled, :last_notified])
  end
end

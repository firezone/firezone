defmodule Domain.Accounts.Account.Changeset do
  use Domain, :changeset
  alias Domain.Accounts.Account

  def create_changeset(attrs) do
    %Account{}
    |> cast(attrs, [:name])
    |> validate_required([:name])
  end
end

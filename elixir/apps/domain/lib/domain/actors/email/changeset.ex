defmodule Domain.Actors.Email.Changeset do
  use Domain, :changeset

  def changeset(account_id, email, attrs) do
    email
    |> cast(attrs, [:email])
    |> put_change(:account_id, account_id)
    |> validate_required([:email])
    |> validate_format(:email, ~r/@/)
    |> assoc_constraint(:account)
    |> assoc_constraint(:actor)
    |> unique_constraint(:email, name: :actor_emails_account_id_email_index)
  end
end

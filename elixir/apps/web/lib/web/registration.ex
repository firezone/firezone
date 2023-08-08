defmodule Web.Registration do
  use Domain, :schema

  alias Domain.{Accounts, Actors}
  alias Web.Registration

  @primary_key false

  embedded_schema do
    field(:email, :string)
    embeds_one(:account, Accounts.Account)
    embeds_one(:actor, Actors.Actor)
  end

  def changeset(%Registration{} = registration, attrs) do
    registration
    |> Ecto.Changeset.cast(attrs, [:email])
    |> Ecto.Changeset.validate_format(:email, ~r/.+@.+/)
    |> Ecto.Changeset.cast_embed(:account, with: &Accounts.Account.Changeset.changeset/2)
    |> Ecto.Changeset.cast_embed(:actor, with: &Actors.Actor.Changeset.changeset/2)
  end
end

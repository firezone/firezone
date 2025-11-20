defmodule Domain.Auth.Identity.Changeset do
  use Domain, :changeset
  alias Domain.Actors
  alias Domain.Auth.Identity

  @idp_create_fields ~w[
    issuer
    idp_id
    name
    given_name
    family_name
    middle_name
    nickname
    preferred_username
    profile
    picture
    email
  ]a

  # Used when creating an identity along with a new actor
  def create(%Identity{} = identity, attrs) do
    identity
    |> cast(attrs, @idp_create_fields ++ ~w[account_id]a)
    |> validate_required(~w[issuer idp_id name account_id]a)
    |> assoc_constraint(:account)
    |> put_subject_trail(:created_by, :system)
    |> changeset()
  end

  # Used to add an identity to an existing actor
  def create(
        %Actors.Actor{} = actor,
        attrs
      ) do
    %Identity{}
    |> cast(attrs, @idp_create_fields)
    |> validate_required(~w[issuer idp_id name]a)
    |> put_change(:actor_id, actor.id)
    |> put_change(:account_id, actor.account_id)
    |> assoc_constraint(:actor)
    |> assoc_constraint(:account)
    |> put_subject_trail(:created_by, :system)
    |> changeset()
  end

  def create_identity(
        %Actors.Actor{account_id: account_id} = actor,
        attrs
      ) do
    %Identity{}
    |> cast(attrs, ~w[email]a)
    |> put_change(:actor_id, actor.id)
    |> put_change(:account_id, account_id)
    |> put_subject_trail(:created_by, :system)
    |> changeset()
  end

  def changeset(changeset) do
    changeset
    |> unique_constraint(:base,
      name: :auth_identities_account_issuer_idp_id_index,
      message: "issuer, idp_id is already taken"
    )
    |> check_constraint(:base,
      name: :issuer_idp_id_both_set_or_neither,
      message: "issuer, idp_id must both be set or neither"
    )
    |> trim_change(~w[
        issuer
        idp_id
        name
        given_name
        family_name
        middle_name
        nickname
        preferred_username
        profile
        picture
        email
      ]a)
  end
end

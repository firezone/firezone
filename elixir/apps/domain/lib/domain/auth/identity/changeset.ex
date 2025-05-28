defmodule Domain.Auth.Identity.Changeset do
  use Domain, :changeset
  alias Domain.Actors
  alias Domain.Auth.{Subject, Identity, Provider}

  def create_identity(
        %Actors.Actor{} = actor,
        %Provider{} = provider,
        attrs,
        %Subject{} = subject
      ) do
    actor
    |> create_identity(provider, attrs)
    |> reset_created_by()
    |> put_subject_trail(:created_by, subject)
  end

  def create_identity(
        %Actors.Actor{account_id: account_id} = actor,
        %Provider{account_id: account_id} = provider,
        attrs
      ) do
    %Identity{}
    |> cast(attrs, ~w[email provider_identifier provider_virtual_state]a)
    |> validate_required(~w[provider_identifier]a)
    |> maybe_put_email_from_identifier()
    |> put_change(:actor_id, actor.id)
    |> put_change(:provider_id, provider.id)
    |> put_change(:account_id, account_id)
    |> put_subject_trail(:created_by, :system)
    |> changeset()
  end

  def create_identity_and_actor(
        %Provider{account_id: account_id} = provider,
        attrs
      ) do
    %Identity{}
    |> cast(attrs, ~w[email provider_identifier provider_state provider_virtual_state]a)
    |> validate_required(~w[provider_identifier]a)
    |> maybe_put_email_from_state()
    |> cast_assoc(:actor,
      with: fn _actor, attrs ->
        Actors.Actor.Changeset.create(account_id, attrs)
        |> put_change(:last_synced_at, DateTime.utc_now())
      end
    )
    |> put_change(:provider_id, provider.id)
    |> put_change(:account_id, account_id)
    |> put_subject_trail(:created_by, :provider)
    |> changeset()
  end

  def update_identity_and_actor(%Identity{} = identity, attrs) do
    identity
    |> cast(attrs, ~w[email provider_state]a)
    |> maybe_put_email_from_state()
    |> cast_assoc(:actor,
      with: fn actor, attrs ->
        Actors.Actor.Changeset.sync(actor, attrs)
      end
    )
    |> put_change(:deleted_at, nil)
    |> changeset()
  end

  def changeset(changeset) do
    changeset
    |> unique_constraint(:provider_identifier,
      name: :auth_identities_account_id_provider_id_provider_identifier_idx
    )
    |> unique_constraint(:email,
      name: :auth_identities_acct_id_provider_id_email_prov_ident_unique_idx
    )
  end

  def update_identity_provider_state(identity_or_changeset, %{} = state, virtual_state \\ %{}) do
    identity_or_changeset
    |> change()
    |> put_change(:provider_state, state)
    |> put_change(:provider_virtual_state, virtual_state)
  end

  def delete_identity(%Identity{} = identity) do
    identity
    |> change()
    |> put_change(:provider_state, %{})
    |> put_change(:provider_virtual_state, %{})
    |> put_default_value(:deleted_at, DateTime.utc_now())
  end

  defp maybe_put_email_from_identifier(changeset) do
    identifier = get_field(changeset, :provider_identifier)
    email = get_field(changeset, :email)

    if is_nil(email) and valid_email?(identifier) do
      put_change(changeset, :email, identifier)
    else
      changeset
    end
  end

  defp maybe_put_email_from_state(changeset) do
    case get_field(changeset, :provider_state) do
      %{"userinfo" => %{"email" => email}} ->
        put_change(changeset, :email, email)

      _ ->
        changeset
    end
  end

  defp valid_email?(email) do
    to_string(email) =~ Domain.Auth.email_regex()
  end
end

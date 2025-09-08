defmodule Domain.Actors.Group.Changeset do
  use Domain, :changeset
  alias Domain.{Auth, Accounts}
  alias Domain.Actors

  @fields ~w[name type synced_at]a

  def upsert_conflict_target do
    {:unsafe_fragment,
     "(account_id, provider_id, provider_identifier) " <>
       "WHERE provider_id IS NOT NULL AND provider_identifier IS NOT NULL"}
  end

  # TODO: Update after `deleted_at` is removed from the DB
  def upsert_on_conflict, do: {:replace, ~w[name updated_at deleted_at]a}

  def create(%Accounts.Account{} = account, attrs, %Auth.Subject{} = subject) do
    %Actors.Group{memberships: []}
    |> cast(attrs, @fields)
    |> validate_required(~w[name type]a)
    |> validate_inclusion(:type, ~w[static]a)
    |> changeset()
    |> put_change(:account_id, account.id)
    |> cast_membership_assocs(account.id)
    |> put_subject_trail(:created_by, subject)
  end

  def create(%Accounts.Account{} = account, attrs) do
    %Actors.Group{memberships: []}
    |> cast(attrs, ~w[name synced_at]a)
    |> validate_required(~w[name]a)
    |> put_change(:type, :managed)
    |> changeset()
    |> put_change(:account_id, account.id)
    |> cast_membership_assocs(account.id)
    |> put_subject_trail(:created_by, :system)
  end

  # TODO: Update after `deleted_at` is removed from the DB
  def create(%Auth.Provider{} = provider, attrs) do
    %Actors.Group{memberships: []}
    |> cast(attrs, ~w[name provider_identifier synced_at]a)
    |> validate_required(~w[name provider_identifier]a)
    |> put_change(:type, :static)
    |> changeset()
    |> put_change(:provider_id, provider.id)
    |> put_change(:account_id, provider.account_id)
    # resurrect synced groups
    |> put_change(:deleted_at, nil)
    |> put_subject_trail(:created_by, :provider)
  end

  def update(%Actors.Group{} = group, attrs) do
    group
    |> cast(attrs, ~w[name synced_at]a)
    |> validate_required(~w[name]a)
    |> validate_inclusion(:type, ~w[static]a)
    |> changeset()
    |> cast_membership_assocs(group.account_id)
  end

  defp changeset(changeset) do
    changeset
    |> trim_change(@fields)
    |> validate_length(:name, min: 1, max: 255)
    |> unique_constraint(:name, name: :actor_groups_account_id_name_index)
  end

  defp cast_membership_assocs(changeset, account_id) do
    case fetch_field(changeset, :type) do
      {_data_or_changes, :static} ->
        cast_assoc(changeset, :memberships,
          with: &Actors.Membership.Changeset.for_group(account_id, &1, &2)
        )

      _other ->
        changeset
    end
  end
end

defmodule Domain.Relays.Group.Changeset do
  use Domain, :changeset
  alias Domain.Auth
  alias Domain.Accounts
  alias Domain.Relays

  @fields ~w[name]a

  def create(attrs) do
    %Relays.Group{}
    |> changeset(attrs)
    |> cast_assoc(:tokens,
      with: fn _token, _attrs ->
        Relays.Token.Changeset.create()
      end,
      required: true
    )
    |> put_change(:created_by, :system)
  end

  def create(%Accounts.Account{} = account, attrs, %Auth.Subject{} = subject) do
    %Relays.Group{account: account}
    |> changeset(attrs)
    |> cast_assoc(:tokens,
      with: fn _token, _attrs ->
        Relays.Token.Changeset.create(account, subject)
      end,
      required: true
    )
    |> put_change(:account_id, account.id)
    |> put_change(:created_by, :identity)
    |> put_change(:created_by_identity_id, subject.identity.id)
  end

  def update(%Relays.Group{} = group, attrs, %Auth.Subject{} = subject) do
    changeset(group, attrs)
    |> cast_assoc(:tokens,
      with: fn _token, _attrs ->
        Relays.Token.Changeset.create(group.account, subject)
      end
    )
  end

  def update(%Relays.Group{} = group, attrs) do
    changeset(group, attrs)
    |> cast_assoc(:tokens,
      with: fn _token, _attrs ->
        Relays.Token.Changeset.create()
      end,
      required: true
    )
  end

  defp changeset(group, attrs) do
    group
    |> cast(attrs, @fields)
    |> trim_change(:name)
    |> put_default_value(:name, &Domain.NameGenerator.generate/0)
    |> validate_required(@fields)
    |> validate_length(:name, min: 1, max: 64)
    |> unique_constraint(:name, name: :relay_groups_name_index)
    |> unique_constraint(:name, name: :relay_groups_account_id_name_index)
  end

  def delete(%Relays.Group{} = group) do
    group
    |> change()
    |> put_default_value(:deleted_at, DateTime.utc_now())
  end
end

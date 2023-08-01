defmodule Domain.Gateways.Group.Changeset do
  use Domain, :changeset
  alias Domain.{Auth, Accounts}
  alias Domain.Gateways

  @fields ~w[name_prefix tags]a

  def create_changeset(%Accounts.Account{} = account, attrs, %Auth.Subject{} = subject) do
    %Gateways.Group{account: account}
    |> changeset(attrs)
    |> put_change(:account_id, account.id)
    |> put_change(:created_by, :identity)
    |> put_change(:created_by_identity_id, subject.identity.id)
    |> cast_assoc(:tokens,
      with: fn _token, _attrs ->
        Gateways.Token.Changeset.create_changeset(account, subject)
      end,
      required: true
    )
  end

  def update_changeset(%Gateways.Group{} = group, attrs) do
    changeset(group, attrs)
  end

  defp changeset(%Gateways.Group{} = group, attrs) do
    group
    |> cast(attrs, @fields)
    |> trim_change(:name_prefix)
    |> put_default_value(:name_prefix, &Domain.NameGenerator.generate/0)
    |> validate_length(:name_prefix, min: 1, max: 64)
    |> validate_length(:tags, min: 0, max: 128)
    |> validate_no_duplicates(:tags)
    |> validate_list_elements(:tags, fn key, value ->
      if String.length(value) > 64 do
        [{key, "should be at most 64 characters long"}]
      else
        []
      end
    end)
    |> validate_required(@fields)
    |> unique_constraint(:name_prefix, name: :gateway_groups_account_id_name_prefix_index)
  end

  def delete_changeset(%Gateways.Group{} = group) do
    group
    |> change()
    |> put_default_value(:deleted_at, DateTime.utc_now())
  end
end

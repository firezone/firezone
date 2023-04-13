defmodule Domain.Relays.Group.Changeset do
  use Domain, :changeset
  alias Domain.Accounts
  alias Domain.Relays

  @fields ~w[name]a

  def create_changeset(%Accounts.Account{} = account, attrs) do
    %Relays.Group{}
    |> changeset(attrs)
    |> put_change(:account_id, account.id)
  end

  def update_changeset(%Relays.Group{} = group, attrs) do
    changeset(group, attrs)
  end

  defp changeset(group, attrs) do
    group
    |> cast(attrs, @fields)
    |> trim_change(:name)
    |> put_default_value(:name, &Domain.NameGenerator.generate/0)
    |> validate_length(:name, min: 1, max: 64)
    |> validate_required(@fields)
    |> unique_constraint([:name])
    |> cast_assoc(:tokens,
      with: fn _token, _attrs ->
        Domain.Relays.Token.Changeset.create_changeset()
      end,
      required: true
    )
  end

  def delete_changeset(%Relays.Group{} = group) do
    group
    |> change()
    |> put_default_value(:deleted_at, DateTime.utc_now())
  end
end

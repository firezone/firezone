defmodule Domain.Accounts.Account.Changeset do
  use Domain, :changeset
  alias Domain.Accounts.Account

  def changeset(account, attrs) do
    account
    |> cast(attrs, [:name, :slug])
    |> validate_required([:name])
    |> validate_name()
    |> trim_change(:name)
    |> put_slug_default()
    |> downcase_slug()
    |> validate_slug()
    |> unique_constraint(:slug, name: :accounts_slug_index)
  end

  def create_changeset(attrs) do
    %Account{}
    |> changeset(attrs)
  end

  defp validate_name(changeset) do
    changeset
    |> validate_length(:name, min: 3, max: 64)
  end

  defp put_slug_default(changeset) do
    changeset
    |> put_default_value(:slug, &Domain.Accounts.generate_unique_slug/0)
  end

  defp validate_slug(changeset) do
    changeset
    |> validate_length(:slug, min: 3, max: 100)
    |> validate_format(:slug, ~r/^[a-zA-Z0-9_]+$/,
      message: "can only contain letters, numbers, and underscores"
    )
    |> validate_change(:slug, fn field, slug ->
      if valid_uuid?(slug) do
        [{field, "cannot be a valid UUID"}]
      else
        []
      end
    end)
  end

  defp downcase_slug(changeset) do
    update_change(changeset, :slug, &String.downcase/1)
  end
end

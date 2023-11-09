defmodule Domain.Accounts.Account.Changeset do
  use Domain, :changeset
  alias Domain.Accounts.Account

  def create(attrs) do
    %Account{}
    |> cast(attrs, [:name, :slug])
    |> changeset()
  end

  defp changeset(changeset) do
    changeset
    |> validate_required([:name])
    |> trim_change(:name)
    |> validate_length(:name, min: 3, max: 64)
    |> prepare_changes(fn changeset -> put_slug_default(changeset) end)
    |> downcase_slug()
    |> validate_slug()
    |> unique_constraint(:slug, name: :accounts_slug_index)
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
    |> validate_exclusion(:slug, [
      "sign_up",
      "sign_in",
      "sign_out",
      "account",
      "admin",
      "system",
      "me",
      "you"
    ])
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

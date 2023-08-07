defmodule Domain.Accounts.Account.Changeset do
  use Domain, :changeset
  alias Domain.Accounts.Account

  def create_changeset(attrs) do
    %Account{}
    |> cast(attrs, [:name, :slug])
    |> validate_required([:name])
    |> validate_length(:name, min: 1, max: 255)
    |> validate_slug()
    |> validate_length(:slug, min: 3, max: 100)
  end

  defp validate_slug(changeset) do
    validate_change(changeset, :slug, fn field, slug ->
      if valid_uuid?(slug) do
        [{field, "must can not be a valid UUID"}]
      else
        []
      end
    end)
  end
end

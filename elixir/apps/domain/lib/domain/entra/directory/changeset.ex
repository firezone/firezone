defmodule Domain.Entra.Directory.Changeset do
  use Domain, :changeset

  @create_fields ~w(tenant_id)a
  @update_fields ~w(
    groups_delta_link
    users_delta_link
    tenant_id
    last_error
    error_emailed_at
    disabled_at
  )a

  def create(struct, attrs) do
    struct
    |> cast(attrs, @create_fields)
    |> changeset()
  end

  def update(struct, attrs) do
    struct
    |> cast(attrs, @update_fields)
    |> changeset()
  end

  defp changeset(changeset) do
    changeset
    |> validate_required([:tenant_id])
    |> validate_length(:tenant_id, is: 36)
    |> validate_length(:last_error, max: 1000)
    |> assoc_constraint(:account)
    |> assoc_constraint(:auth_provider)
  end
end

defmodule Domain.Entra.Directory.Changeset do
  use Domain, :changeset

  @required_fields ~w(account_id auth_provider_id client_id client_secret tenant_id)a
  @update_fields ~w(
    client_id
    client_secret
    tenant_id
    last_error
    error_emailed_at
    disabled_at
  )a

  def create(struct, attrs) do
    struct
    |> cast(attrs, @required_fields)
    |> changeset()
  end

  def update(struct, attrs) do
    struct
    |> cast(attrs, @update_fields)
    |> changeset()
  end

  defp changeset(changeset) do
    changeset
    |> validate_required(@required_fields)
    # tenant_id can be the UUID or the human name
    |> validate_length(:tenant_id, max: 255)
    |> validate_length(:last_error, max: 1000)
    |> assoc_constraint(:account)
    |> assoc_constraint(:auth_provider)
  end
end

defmodule Domain.Entra.Directory do
  use Domain, :schema

  schema "entra_directories" do
    belongs_to :account, Domain.Accounts.Account
    field :tenant_id, :string

    field :issuer, :string
    field :name, :string, default: "Entra"
    field :error_count, :integer, read_after_writes: true
    field :is_disabled, :boolean, default: false, read_after_writes: true
    field :disabled_reason, :string
    field :synced_at, :utc_datetime_usec
    field :error, :string
    field :error_emailed_at, :utc_datetime_usec

    field :is_verified, :boolean, virtual: true, default: false

    subject_trail(~w[actor identity system]a)
    timestamps()
  end

  def changeset(changeset) do
    changeset
    |> validate_required([:name, :tenant_id, :issuer, :is_verified])
    |> validate_length(:tenant_id, min: 1, max: 255)
    |> validate_length(:issuer, min: 1, max: 2_000)
    |> validate_length(:name, min: 1, max: 255)
    |> validate_number(:error_count, greater_than_or_equal_to: 0)
    |> validate_length(:error, max: 2_000)
    |> assoc_constraint(:account)
    |> unique_constraint(:tenant_id,
      name: :entra_directories_account_id_tenant_id_index,
      message: "An Entra directory for this tenant already exists."
    )
    |> unique_constraint(:issuer,
      name: :entra_directories_account_id_issuer_index,
      message: "An Entra directory for this issuer already exists."
    )
    |> unique_constraint(:name,
      name: :entra_directories_account_id_name_index,
      message: "An Entra directory with this name already exists."
    )
    |> foreign_key_constraint(:account_id, name: :entra_directories_account_id_fkey)
  end
end

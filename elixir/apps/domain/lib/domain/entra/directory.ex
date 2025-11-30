defmodule Domain.Entra.Directory do
  use Domain, :schema

  schema "entra_directories" do
    belongs_to :account, Domain.Account

    belongs_to :directory, Domain.Directory,
      foreign_key: :id,
      define_field: false

    field :tenant_id, :string

    field :name, :string, default: "Entra"
    field :errored_at, :utc_datetime_usec
    field :is_disabled, :boolean, default: false, read_after_writes: true
    field :disabled_reason, :string
    field :synced_at, :utc_datetime_usec
    field :error_message, :string
    field :error_email_count, :integer, default: 0, read_after_writes: true
    field :sync_all_groups, :boolean, default: false, read_after_writes: true
    field :is_verified, :boolean, default: false, read_after_writes: true

    timestamps()
  end

  def changeset(changeset) do
    changeset
    |> validate_required([:name, :tenant_id, :is_verified])
    |> validate_length(:tenant_id, min: 1, max: 255)
    |> validate_length(:name, min: 1, max: 255)
    |> validate_number(:error_email_count, greater_than_or_equal_to: 0)
    |> assoc_constraint(:account)
    |> assoc_constraint(:directory)
    |> unique_constraint(:tenant_id,
      name: :entra_directories_account_id_tenant_id_index,
      message: "An Entra directory for this tenant already exists."
    )
    |> unique_constraint(:name,
      name: :entra_directories_account_id_name_index,
      message: "An Entra directory with this name already exists."
    )
  end
end

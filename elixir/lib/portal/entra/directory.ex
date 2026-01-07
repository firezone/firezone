defmodule Portal.Entra.Directory do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  schema "entra_directories" do
    belongs_to :account, Portal.Account

    belongs_to :directory, Portal.Directory,
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

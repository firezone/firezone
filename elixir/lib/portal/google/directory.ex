defmodule Portal.Google.Directory do
  use Ecto.Schema
  import Ecto.Changeset
  import Portal.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  schema "google_directories" do
    belongs_to :account, Portal.Account

    belongs_to :directory, Portal.Directory,
      foreign_key: :id,
      define_field: false

    field :domain, :string

    field :name, :string, default: "Google"
    field :impersonation_email, :string
    field :errored_at, :utc_datetime_usec
    field :is_disabled, :boolean, default: false, read_after_writes: true
    field :disabled_reason, :string
    field :synced_at, :utc_datetime_usec
    field :error_message, :string
    field :error_email_count, :integer, default: 0, read_after_writes: true
    field :is_verified, :boolean, default: false, read_after_writes: true
    field :legacy_service_account_key, :map, redact: true

    timestamps()
  end

  def changeset(%Ecto.Changeset{} = changeset) do
    changeset
    |> validate_required([:domain, :is_verified, :name, :impersonation_email])
    |> validate_email(:impersonation_email)
    |> validate_length(:domain, min: 1, max: 255)
    |> validate_length(:name, min: 1, max: 255)
    |> validate_number(:error_email_count, greater_than_or_equal_to: 0)
    |> assoc_constraint(:account)
    |> assoc_constraint(:directory)
    |> unique_constraint(:domain,
      name: :google_directories_account_id_domain_index,
      message: "A Google directory for this domain already exists."
    )
    |> unique_constraint(:name,
      name: :google_directories_account_id_name_index,
      message: "A Google directory with this name already exists."
    )
  end
end

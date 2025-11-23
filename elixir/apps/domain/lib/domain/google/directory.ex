defmodule Domain.Google.Directory do
  use Domain, :schema

  @primary_key false
  schema "google_directories" do
    # Allows setting the id manually for easier associations
    field :id, Ecto.UUID, primary_key: true
    belongs_to :account, Domain.Accounts.Account

    belongs_to :directory, Domain.Directory,
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

    timestamps()
  end

  def changeset(changeset) do
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

defmodule Domain.Okta.Directory do
  use Domain, :schema

  schema "okta_directories" do
    belongs_to :account, Domain.Accounts.Account

    belongs_to :directory, Domain.Directory,
      foreign_key: :id,
      define_field: false

    field :client_id, :string
    field :private_key_jwk, :map
    field :kid, :string
    field :okta_domain, :string

    field :name, :string, default: "Okta"
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
    |> validate_required([
      :name,
      :okta_domain,
      :client_id,
      :private_key_jwk,
      :kid,
      :is_verified
    ])
    |> validate_length(:okta_domain, min: 1, max: 255)
    |> validate_length(:name, min: 1, max: 255)
    |> validate_number(:error_email_count, greater_than_or_equal_to: 0)
    |> assoc_constraint(:account)
    |> assoc_constraint(:directory)
    |> unique_constraint(:okta_domain,
      name: :okta_directories_account_id_okta_domain_index,
      message: "An Okta directory for this Okta domain already exists."
    )
    |> unique_constraint(:name,
      name: :okta_directories_account_id_name_index,
      message: "An Okta directory with this name already exists."
    )
  end
end

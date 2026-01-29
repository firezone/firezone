defmodule Portal.Okta.Directory do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  @type t :: %__MODULE__{
          id: Ecto.UUID.t(),
          account_id: Ecto.UUID.t(),
          client_id: String.t(),
          private_key_jwk: map(),
          kid: String.t(),
          okta_domain: String.t(),
          name: String.t(),
          errored_at: DateTime.t() | nil,
          is_disabled: boolean(),
          disabled_reason: String.t() | nil,
          synced_at: DateTime.t() | nil,
          error_message: String.t() | nil,
          error_email_count: non_neg_integer(),
          is_verified: boolean(),
          inserted_at: DateTime.t(),
          updated_at: DateTime.t()
        }

  schema "okta_directories" do
    belongs_to :account, Portal.Account

    belongs_to :directory, Portal.Directory,
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

  def changeset(%Ecto.Changeset{} = changeset) do
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

defmodule Portal.Sophos.PostureProvider do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  @type t :: %__MODULE__{}

  schema "sophos_posture_providers" do
    belongs_to :account, Portal.Account, primary_key: true

    # Shares its id with the posture_providers row; set both when creating.
    field :id, :binary_id, primary_key: true

    belongs_to :posture_provider, Portal.PostureProvider,
      foreign_key: :id,
      define_field: false

    field :name, :string, virtual: true, default: "Sophos XDR"
    field :client_id, :string
    field :client_secret, :string, redact: true
    field :tenant_id, :string
    field :data_region_url, :string
    field :is_verified, :boolean, default: false, read_after_writes: true
    field :is_disabled, :boolean, default: false, read_after_writes: true
    field :disabled_reason, :string
    field :synced_at, :utc_datetime_usec
    field :errored_at, :utc_datetime_usec
    field :error_message, :string
    field :error_email_count, :integer, default: 0, read_after_writes: true

    has_many :devices, Portal.Sophos.Device,
      foreign_key: :posture_provider_id,
      references: :id

    timestamps()
  end

  def changeset(%Ecto.Changeset{} = changeset) do
    changeset
    |> update_change(:client_id, &String.trim/1)
    |> validate_required([:client_id, :client_secret, :tenant_id, :data_region_url, :is_verified])
    |> validate_length(:client_id, min: 1, max: 255)
    |> validate_length(:client_secret, min: 1, max: 4096)
    |> validate_length(:tenant_id, min: 1, max: 255)
    |> validate_format(:data_region_url, Portal.Sophos.APIClient.data_region_url_format())
    |> validate_number(:error_email_count, greater_than_or_equal_to: 0)
    |> assoc_constraint(:account)
    |> assoc_constraint(:posture_provider)
    |> unique_constraint(:tenant_id,
      name: :sophos_posture_providers_account_id_tenant_id_index,
      message: "This Sophos tenant is already connected."
    )
  end
end

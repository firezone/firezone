defmodule Portal.Intune.Integration do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  schema "intune_integrations" do
    belongs_to :account, Portal.Account, primary_key: true

    # Shares its id with the device_integrations row; set both when creating.
    field :id, :binary_id, primary_key: true

    belongs_to :device_integration, Portal.DeviceIntegration,
      foreign_key: :id,
      define_field: false

    field :name, :string, default: "Microsoft Intune"
    field :tenant_id, :string
    field :is_verified, :boolean, default: false, read_after_writes: true
    field :is_disabled, :boolean, default: false, read_after_writes: true
    field :disabled_reason, :string
    field :synced_at, :utc_datetime_usec
    field :errored_at, :utc_datetime_usec
    field :error_message, :string
    field :error_email_count, :integer, default: 0, read_after_writes: true

    has_many :devices, Portal.Intune.Device,
      foreign_key: :device_integration_id,
      references: :id

    timestamps()
  end

  def changeset(%Ecto.Changeset{} = changeset) do
    changeset
    |> validate_required([:name, :tenant_id, :is_verified])
    |> validate_length(:name, min: 1, max: 255)
    |> validate_length(:tenant_id, min: 1, max: 255)
    |> validate_number(:error_email_count, greater_than_or_equal_to: 0)
    |> assoc_constraint(:account)
    |> assoc_constraint(:device_integration)
  end
end

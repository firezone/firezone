defmodule Portal.DeviceIntegration do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
  @foreign_key_type :binary_id

  schema "device_integrations" do
    belongs_to :account, Portal.Account, primary_key: true
    field :id, :binary_id, primary_key: true
    field :type, Ecto.Enum, values: [:intune]

    has_one :intune_integration, Portal.Intune.Integration,
      references: :id,
      foreign_key: :id,
      where: [type: :intune]
  end

  def changeset(%Ecto.Changeset{} = changeset) do
    changeset
    |> validate_required([:type])
    |> assoc_constraint(:account)
    |> unique_constraint(:type, name: :device_integrations_account_id_type_index)
    |> check_constraint(:type, name: :type_must_be_valid, message: "is not valid")
  end
end

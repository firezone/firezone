defmodule Portal.PostureProvider do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
  @foreign_key_type :binary_id

  schema "posture_providers" do
    belongs_to :account, Portal.Account, primary_key: true
    field :id, :binary_id, primary_key: true
    field :type, Ecto.Enum, values: ~w[intune iru defender santa sentinelone]a

    # Names the provider to an admin whatever its type, so it is unique across
    # the account rather than per type.
    field :name, :string

    # A provider owns exactly one typed row and they share an id, so the type
    # column on this row is what tells them apart rather than a filter.
    has_one :intune_posture_provider, Portal.Intune.PostureProvider,
      references: :id,
      foreign_key: :id

    has_one :iru_posture_provider, Portal.Iru.PostureProvider,
      references: :id,
      foreign_key: :id

    has_one :defender_posture_provider, Portal.Defender.PostureProvider,
      references: :id,
      foreign_key: :id

    has_one :santa_posture_provider, Portal.Santa.PostureProvider,
      references: :id,
      foreign_key: :id

    has_one :sentinelone_posture_provider, Portal.SentinelOne.PostureProvider,
      references: :id,
      foreign_key: :id
  end

  def changeset(%Ecto.Changeset{} = changeset) do
    changeset
    |> validate_required([:type, :name])
    |> validate_length(:name, min: 1, max: 255)
    |> assoc_constraint(:account)
    |> check_constraint(:type, name: :type_must_be_valid, message: "is not valid")
    |> unique_constraint(:name,
      name: :posture_providers_account_id_name_index,
      message: "A posture provider with this name already exists."
    )
  end
end

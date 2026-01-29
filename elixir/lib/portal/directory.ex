defmodule Portal.Directory do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  schema "directories" do
    belongs_to :account, Portal.Account, primary_key: true
    field :id, :binary_id, primary_key: true
    field :type, Ecto.Enum, values: ~w[google entra okta]a

    has_one :google_directory, Portal.Google.Directory,
      references: :id,
      foreign_key: :id,
      where: [type: :google]

    has_one :entra_directory, Portal.Entra.Directory,
      references: :id,
      foreign_key: :id,
      where: [type: :entra]

    has_one :okta_directory, Portal.Okta.Directory,
      references: :id,
      foreign_key: :id,
      where: [type: :okta]
  end

  def changeset(%Ecto.Changeset{} = changeset) do
    changeset
    |> validate_required(~w[type]a)
    |> assoc_constraint(:account)
    |> check_constraint(:type, name: :type_must_be_valid, message: "is not valid")
  end
end

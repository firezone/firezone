defmodule Portal.X509.AuthProvider do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  @type t :: %__MODULE__{}

  schema "x509_auth_providers" do
    belongs_to :account, Portal.Account, primary_key: true
    field :id, :binary_id, primary_key: true

    belongs_to :auth_provider, Portal.AuthProvider,
      foreign_key: :id,
      define_field: false

    field :name, :string

    field :context, Ecto.Enum,
      values: ~w[clients_only]a,
      default: :clients_only

    field :is_disabled, :boolean, read_after_writes: true, default: true

    timestamps()
  end

  def changeset(%Ecto.Changeset{} = changeset) do
    changeset
    |> validate_required([:name, :context])
    |> assoc_constraint(:account)
    |> assoc_constraint(:auth_provider)
    |> unique_constraint(:account_id,
      name: :x509_auth_providers_account_id_index,
      message: "An X.509 authentication provider for this account already exists."
    )
    |> check_constraint(:context, name: :context_must_be_clients_only)
  end
end

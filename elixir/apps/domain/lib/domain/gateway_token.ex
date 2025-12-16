defmodule Domain.GatewayToken do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  schema "gateway_tokens" do
    belongs_to :account, Domain.Account, primary_key: true
    field :id, :binary_id, primary_key: true, autogenerate: true

    belongs_to :site, Domain.Site

    field :secret_hash, :string, redact: true
    field :secret_salt, :string, redact: true

    # Used only during creation
    field :secret_fragment, :string, virtual: true, redact: true

    timestamps(updated_at: false)
  end

  def changeset(%Ecto.Changeset{} = changeset) do
    changeset
    |> assoc_constraint(:account)
    |> assoc_constraint(:site)
  end
end

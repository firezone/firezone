defmodule Portal.Ops.Passkey do
  @moduledoc """
  A WebAuthn passkey of an ops admin. Every admin must keep at least one.
  `public_key` holds the COSE key in Erlang term format, see `cose_key/1`.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  schema "passkeys" do
    belongs_to :admin, Portal.Ops.Admin

    field :name, :string
    field :credential_id, :binary
    field :public_key, :binary
    field :sign_count, :integer, default: 0
    field :last_used_at, :utc_datetime_usec

    timestamps()
  end

  @doc "Decodes the stored COSE key for `Wax.authenticate/6`."
  @spec cose_key(t()) :: map()
  # Only the server writes this column, from `encode_cose_key/1`.
  # sobelow_skip ["Misc.BinToTerm"]
  def cose_key(%__MODULE__{public_key: public_key}), do: :erlang.binary_to_term(public_key, [:safe])

  @doc "Encodes a COSE key from `Wax.register/3` for storage."
  @spec encode_cose_key(map()) :: binary()
  def encode_cose_key(cose_key) when is_map(cose_key), do: :erlang.term_to_binary(cose_key)

  def changeset(%Ecto.Changeset{} = changeset) do
    changeset
    |> update_change(:name, &String.trim/1)
    |> validate_required([:admin_id, :name, :credential_id, :public_key, :sign_count])
    |> validate_length(:name, min: 1, max: 64)
    |> validate_number(:sign_count, greater_than_or_equal_to: 0)
    |> assoc_constraint(:admin)
    |> unique_constraint(:credential_id, name: :passkeys_credential_id_index)
  end
end

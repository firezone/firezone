defmodule Portal.RelayToken do
  # credo:disable-for-this-file Credo.Check.Warning.MissingChangesetFunction
  use Ecto.Schema

  @primary_key false
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  schema "relay_tokens" do
    field :id, :binary_id, primary_key: true, autogenerate: true

    field :secret_hash, :string, redact: true
    field :secret_salt, :string, redact: true

    # Used only during creation
    field :secret_fragment, :string, virtual: true, redact: true

    timestamps(updated_at: false)
  end
end

defmodule Portal.OcspStatus do
  @moduledoc """
  What an OCSP responder last said about one certificate.

  Rows are owned by the OCSP fetch job. Unlike a cached CRL, absence here does
  not mean a certificate is good, only that it has never been asked about, and
  `next_update` bounds how long the answer stands.

  Keyed on the issuer as well as the serial, since a serial identifies a
  certificate only together with whoever issued it.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  @statuses ~w[good revoked]

  @type t :: %__MODULE__{
          account_id: Ecto.UUID.t(),
          issuer: binary(),
          serial: String.t(),
          status: String.t(),
          revoked_at: DateTime.t() | nil,
          reason: String.t() | nil,
          produced_at: DateTime.t() | nil,
          this_update: DateTime.t() | nil,
          next_update: DateTime.t() | nil,
          updated_at: DateTime.t()
        }

  schema "ocsp_statuses" do
    belongs_to :account, Portal.Account, primary_key: true

    field :issuer, :binary, primary_key: true
    field :serial, :string, primary_key: true

    field :status, :string
    field :revoked_at, :utc_datetime
    field :reason, :string

    field :produced_at, :utc_datetime
    field :this_update, :utc_datetime
    field :next_update, :utc_datetime

    timestamps(inserted_at: false)
  end

  def changeset(%Ecto.Changeset{} = changeset) do
    changeset
    |> validate_required([:issuer, :serial, :status])
    |> validate_inclusion(:status, @statuses)
    |> validate_length(:issuer, max: 1024, count: :bytes)
    |> validate_length(:serial, max: 255)
    |> assoc_constraint(:account)
  end

  def statuses, do: @statuses
end

defmodule Portal.Ops.Admin do
  @moduledoc """
  A person who can sign in to the ops dashboard. Only provisioned emails can sign in,
  see `Portal.Ops.provision_admin/1`. The Google account subject is pinned on the
  first sign-in.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @timestamps_opts [type: :utc_datetime_usec]

  schema "admins" do
    field :email, :string
    field :google_sub, :string
    field :last_signed_in_at, :utc_datetime_usec

    has_many :passkeys, Portal.Ops.Passkey

    timestamps()
  end

  @doc "Lowercases an email and strips surrounding whitespace."
  @spec normalize_email(String.t()) :: String.t()
  def normalize_email(email) when is_binary(email) do
    email |> String.trim() |> String.downcase()
  end

  def changeset(%Ecto.Changeset{} = changeset) do
    changeset
    |> update_change(:email, &normalize_email/1)
    |> validate_required([:email])
    |> validate_length(:email, max: 255)
    |> validate_format(:email, ~r/\A[^@\s]+@[^@\s]+\.[^@\s]+\z/)
    |> unique_constraint(:email, name: :admins_email_index)
    |> unique_constraint(:google_sub, name: :admins_google_sub_index)
  end
end

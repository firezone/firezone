defmodule Portal.KnownMxDomain do
  @moduledoc """
  Mail server domains of known-good email providers. An email sign-up goes ahead
  without review when every MX host of the email domain is one of these domains or
  ends with `.` plus one of them. Stored as lowercase ASCII without a trailing dot.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @primary_key {:domain, :string, autogenerate: false}

  schema "known_mx_domains" do
  end

  @doc "The format every stored domain must have."
  @spec format() :: Regex.t()
  def format, do: ~r/\A[a-z0-9-]+(\.[a-z0-9-]+)+\z/

  def changeset(%Ecto.Changeset{} = changeset) do
    changeset
    |> validate_required([:domain])
    |> validate_length(:domain, max: 253)
    |> validate_format(:domain, format())
    |> check_constraint(:domain, name: :domain_format)
    |> unique_constraint(:domain, name: :known_mx_domains_pkey)
  end
end

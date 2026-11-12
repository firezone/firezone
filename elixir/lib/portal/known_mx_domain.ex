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

  @doc """
  The format every stored domain must have: two or more labels of lowercase letters,
  digits and inner hyphens, each at most 63 characters, and 253 characters in total.
  """
  @spec format() :: Regex.t()
  def format,
    do: ~r/\A(?=.{1,253}\z)([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\z/

  @doc "Lowercases a domain and strips surrounding whitespace and dots."
  @spec normalize(String.t()) :: String.t()
  def normalize(domain) when is_binary(domain) do
    domain |> String.trim() |> String.trim(".") |> String.downcase()
  end

  def changeset(%Ecto.Changeset{} = changeset) do
    changeset
    |> update_change(:domain, &normalize/1)
    |> validate_required([:domain])
    |> validate_format(:domain, format())
    |> check_constraint(:domain, name: :domain_format)
    |> unique_constraint(:domain, name: :known_mx_domains_pkey)
  end
end

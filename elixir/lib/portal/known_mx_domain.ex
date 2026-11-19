defmodule Portal.KnownMxDomain do
  @moduledoc """
  Mail server domains with a verdict. An MX host matches a domain when it is that
  domain or ends with `.` plus that domain. An email sign-up is blocked when any MX
  host matches a `:deny` domain, and goes ahead without review when every MX host
  matches an `:allow` domain. Stored as lowercase ASCII without a trailing dot.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @primary_key {:domain, :string, autogenerate: false}

  schema "known_mx_domains" do
    field :verdict, Ecto.Enum, values: [:allow, :deny]
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
    |> validate_required([:domain, :verdict])
    |> validate_format(:domain, format())
    |> check_constraint(:domain, name: :domain_format)
    |> check_constraint(:verdict, name: :verdict_values)
    |> unique_constraint(:domain, name: :known_mx_domains_pkey)
  end
end

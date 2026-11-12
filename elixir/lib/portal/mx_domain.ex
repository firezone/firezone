defmodule Portal.MXDomain do
  @moduledoc """
  A mail server domain rated by an operator.

  A domain covers itself and every name under it, so `mail.tm` covers the mail
  server `in.mail.tm`. Sign-ups whose mail servers fall under a `:bad` domain get
  no verification email. `:good` domains are recorded for reference only.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
  @timestamps_opts [type: :utc_datetime_usec]

  # One or more labels of letters, digits and hyphens, with at least one dot.
  @domain_format ~r/\A(?=.{1,253}\z)([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\z/

  @type rating :: :good | :bad
  @type t :: %__MODULE__{
          domain: String.t(),
          rating: rating(),
          note: String.t() | nil,
          inserted_at: DateTime.t(),
          updated_at: DateTime.t()
        }

  schema "mx_domains" do
    field :domain, :string, primary_key: true
    field :rating, Ecto.Enum, values: [:good, :bad]
    field :note, :string

    timestamps()
  end

  @spec changeset(Ecto.Changeset.t()) :: Ecto.Changeset.t()
  def changeset(%Ecto.Changeset{} = changeset) do
    changeset
    |> update_change(:domain, &normalize_domain/1)
    |> update_change(:note, &String.trim/1)
    |> validate_required([:domain, :rating])
    |> validate_format(:domain, @domain_format, message: "must be a domain name like mail.example.com")
    |> validate_note()
    |> check_constraint(:rating, name: :mx_domains_rating)
    |> check_constraint(:domain, name: :mx_domains_domain_lowercase)
    |> check_constraint(:note, name: :mx_domains_bad_note)
  end

  # Bad domains block sign-ups, so each one has to say why it was added.
  defp validate_note(changeset) do
    if get_field(changeset, :rating) == :bad do
      validate_required(changeset, [:note], message: "is required for bad domains")
    else
      changeset
    end
  end

  @doc """
  Lowercases a domain and strips surrounding whitespace and a trailing dot.
  """
  @spec normalize_domain(String.t()) :: String.t()
  def normalize_domain(domain) when is_binary(domain) do
    domain |> String.trim() |> String.trim_trailing(".") |> String.downcase()
  end

  @doc """
  Returns the domain and each parent domain with at least two labels, so a
  top-level domain on its own is never matched.

      iex> Portal.MXDomain.candidates("in.mail.tm")
      ["in.mail.tm", "mail.tm"]
  """
  @spec candidates(String.t()) :: [String.t()]
  def candidates(domain) when is_binary(domain) do
    labels = domain |> normalize_domain() |> String.split(".", trim: true)

    for count <- length(labels)..2//-1 do
      labels |> Enum.take(-count) |> Enum.join(".")
    end
  end
end

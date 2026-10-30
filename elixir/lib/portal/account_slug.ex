defmodule Portal.AccountSlug do
  @moduledoc """
  Every slug an account ever used. Old slugs keep redirecting to the account,
  and no other account can claim them.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @primary_key {:slug, :string, autogenerate: false}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  schema "account_slugs" do
    belongs_to :account, Portal.Account

    timestamps(updated_at: false)
  end

  @doc "A slug and its hyphen and underscore twins, which count as one slug."
  @spec spellings(String.t()) :: [String.t()]
  def spellings(slug) do
    Enum.uniq([slug, String.replace(slug, "_", "-"), String.replace(slug, "-", "_")])
  end

  @doc "The one spelling the shared registry stores for a slug and its twins."
  @spec canonical(String.t()) :: String.t()
  def canonical(slug) do
    slug |> String.downcase() |> String.replace("-", "_")
  end

  def changeset(%Ecto.Changeset{} = changeset) do
    changeset
    |> validate_required([:slug])
    |> unique_constraint(:slug, name: :account_slugs_pkey)
    |> assoc_constraint(:account)
  end
end

defmodule Portal.AccountSlug do
  @moduledoc """
  Every slug an account ever used. Old slugs keep redirecting to the account,
  and no other account can claim them.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  schema "account_slugs" do
    belongs_to :account, Portal.Account

    field :slug, :string

    timestamps(updated_at: false)
  end

  def changeset(%Ecto.Changeset{} = changeset) do
    changeset
    |> validate_required([:slug])
    |> unique_constraint(:slug, name: :account_slugs_slug_index)
    |> assoc_constraint(:account)
  end
end

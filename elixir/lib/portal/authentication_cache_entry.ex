defmodule Portal.AuthenticationCacheEntry do
  # credo:disable-for-this-file Credo.Check.Warning.MissingChangesetFunction
  use Ecto.Schema

  @primary_key false
  @timestamps_opts [type: :utc_datetime_usec]

  schema "authentication_cache_entries" do
    field :key, :string, primary_key: true
    field :value, :map
    field :expires_at, :utc_datetime_usec

    timestamps(updated_at: false)
  end
end

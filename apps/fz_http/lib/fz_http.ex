defmodule FzHttp do
  def schema do
    quote do
      use Ecto.Schema

      @primary_key {:id, :binary_id, autogenerate: true}
      @foreign_key_type :binary_id

      @timestamps_opts [type: :utc_datetime_usec]

      @type id :: binary()
    end
  end

  @doc """
  When used, dispatch to the appropriate schema/context/changeset/query/etc.
  """
  defmacro __using__(which) when is_atom(which) do
    apply(__MODULE__, which, [])
  end
end

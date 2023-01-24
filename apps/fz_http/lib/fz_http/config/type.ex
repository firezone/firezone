defmodule FzHttp.Config.Type do
  defmacro __using__(opts) do
    quote do
      use Ecto.Type

      @behaviour FzHttp.Config.Type

      @ecto_type unquote(Keyword.fetch!(opts, :ecto_type))

      defdelegate type, to: @ecto_type
      defdelegate cast(value), to: @ecto_type
      defdelegate load(data), to: @ecto_type
      defdelegate dump(struct), to: @ecto_type
    end
  end

  @callback from_string(source :: String.t(), value :: String.t()) :: any()

  @callback changeset(key :: atom(), value :: any()) :: Ecto.Changeset.t()

  @callback validate_value_changeset(
              changeset :: Ecto.Changeset.t(),
              key :: atom(),
              opts :: Keyword.t()
            ) :: Ecto.Changeset.t()
end

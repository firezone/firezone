defmodule Web.LiveErrors do
  defmodule NotFoundError do
    defexception message: "Not Found"

    defimpl Plug.Exception do
      def status(_exception), do: 404
      def actions(_exception), do: []
    end
  end
end

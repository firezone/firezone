defmodule Web.LiveErrors do
  defmodule NotFoundError do
    defexception message: "Not Found"

    defimpl Plug.Exception do
      def status(_exception), do: 404
      def actions(_exception), do: []
    end
  end

  defmodule InvalidRequestError do
    defexception message: "Unprocessable Entity"

    defimpl Plug.Exception do
      def status(_exception), do: 422
      def actions(_exception), do: []
    end
  end
end

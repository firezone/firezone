defmodule PortalWeb.LiveErrors do
  defmodule NotFoundError do
    defexception message: "Not Found", skip_sentry: false

    defimpl Plug.Exception do
      def status(_exception), do: 404
      def actions(_exception), do: []
    end
  end

  # this is not a styled error because only security scanners that
  # try to manipulate the request will see it
  defmodule InvalidParamsError do
    defexception message: "Unprocessable Content"

    defimpl Plug.Exception do
      def status(_exception), do: 422
      def actions(_exception), do: []
    end
  end
end

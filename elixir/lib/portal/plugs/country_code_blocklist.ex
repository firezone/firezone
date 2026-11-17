defmodule Portal.Plugs.CountryCodeBlocklist do
  @behaviour Plug

  import Plug.Conn

  @forbidden_body "Forbidden"

  @impl true
  def init(opts), do: opts

  # Endpoint plugs are initialized at compile time in releases, before
  # runtime.exs sets the blocklist, so it is read on every request.
  @impl true
  def call(conn, _opts) do
    blocked_country_codes =
      Portal.Config.get_env(:portal, :country_code_blocklist, [])
      |> normalize_country_codes()

    if blocked_country_code?(conn, blocked_country_codes), do: deny(conn), else: conn
  end

  defp blocked_country_code?(_conn, []), do: false

  defp blocked_country_code?(conn, blocked_country_codes) do
    case resolved_country_code(conn) do
      nil -> false
      country_code -> country_code in blocked_country_codes
    end
  end

  defp resolved_country_code(conn) do
    case Portal.Geo.locate(conn.remote_ip, conn.req_headers) do
      {country_code, _city, _coords} when is_binary(country_code) -> String.upcase(country_code)
      _other -> nil
    end
  end

  defp deny(conn) do
    conn
    |> send_resp(:forbidden, @forbidden_body)
    |> halt()
  end

  defp normalize_country_codes(country_codes) do
    country_codes
    |> Enum.map(&to_string/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.map(&String.upcase/1)
  end
end

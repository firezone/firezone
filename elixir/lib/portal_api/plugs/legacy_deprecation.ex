defmodule PortalAPI.Plugs.LegacyDeprecation do
  @moduledoc """
  Marks a response as deprecated per RFC 8594.

  Used on the legacy unversioned API routes to steer callers towards their
  `/v1` equivalents, and on individual `/v1` routes (like the multi-owner
  gateway token create endpoint) that are deprecated ahead of the next
  removal, independent of the version boundary.

  Sets:

    * `Deprecation: true`
    * `Sunset: <RFC 1123 date>` - when the route stops being served. Defaults
      to the global legacy-route sunset date (`config :portal, PortalAPI.Plugs.LegacyDeprecation,
      sunset_at: ~D[...]`), or can be overridden per-route via the `:sunset` plug option.
    * `Link: <.../v1/...>; rel="successor-version"` - the `/v1` equivalent of
      the request path, when the request itself isn't already under `/v1`.
  """

  import Plug.Conn

  @spec init(keyword()) :: keyword()
  def init(opts), do: opts

  @spec call(Plug.Conn.t(), keyword()) :: Plug.Conn.t()
  def call(conn, opts) do
    conn
    |> put_resp_header("deprecation", "true")
    |> put_resp_header("sunset", sunset_header(opts))
    |> maybe_put_link_header()
  end

  defp sunset_header(opts) do
    opts
    |> Keyword.get_lazy(:sunset, &default_sunset_date/0)
    |> to_http_date()
  end

  defp default_sunset_date do
    Application.fetch_env!(:portal, __MODULE__) |> Keyword.fetch!(:sunset_at)
  end

  defp to_http_date(%Date{} = date) do
    date
    |> DateTime.new!(~T[00:00:00], "Etc/UTC")
    |> Calendar.strftime("%a, %d %b %Y %H:%M:%S GMT")
  end

  defp maybe_put_link_header(%Plug.Conn{request_path: "/v1/" <> _} = conn), do: conn

  defp maybe_put_link_header(conn) do
    put_resp_header(conn, "link", ~s(<#{v1_path(conn)}>; rel="successor-version"))
  end

  defp v1_path(conn), do: "/v1" <> conn.request_path
end

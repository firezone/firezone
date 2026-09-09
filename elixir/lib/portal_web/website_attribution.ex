defmodule PortalWeb.WebsiteAttribution do
  @moduledoc """
  Moves consented website attribution from the query string into the portal session.
  """

  @behaviour Plug

  import Plug.Conn

  alias Portal.Analytics.PostHog

  @distinct_id_param "fz_website_id"
  @pathname_param "fz_website_path"
  @session_key "website_attribution"
  @source "www.firezone.dev"
  @click_params ~w[oppref gclid gbraid wbraid]
  @marketing_params ["fz_marketing" | Enum.map(@click_params, &("fz_" <> &1))]

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%Plug.Conn{method: "GET"} = conn, _opts) do
    conn = fetch_query_params(conn)

    if attribution_params_present?(conn.query_params) do
      conn
      |> maybe_store_attribution(conn.query_params)
      |> Phoenix.Controller.redirect(to: clean_request_target(conn))
      |> halt()
    else
      conn
    end
  end

  def call(conn, _opts), do: conn

  @spec fetch(map()) :: PostHog.attribution() | nil
  def fetch(session), do: Map.get(session, @session_key)

  @spec pop(Plug.Conn.t()) :: {Plug.Conn.t(), PostHog.attribution() | nil}
  def pop(conn) do
    attribution = get_session(conn, @session_key)
    {delete_session(conn, @session_key), attribution}
  end

  defp attribution_params_present?(params) do
    Map.has_key?(params, @distinct_id_param) or Map.has_key?(params, @pathname_param) or
      Map.has_key?(params, "fz_marketing")
  end

  defp maybe_store_attribution(conn, params) do
    conn = store_marketing_attribution(conn, params)
    with {:ok, distinct_id} <- valid_distinct_id(params[@distinct_id_param]),
         {:ok, website_path} <- valid_website_path(params[@pathname_param]) do
      attribution = %{
        "distinct_id" => distinct_id,
        "source" => @source,
        "website_path" => website_path
      }

      PostHog.capture_portal_landing(attribution, conn.request_path)
      put_session(conn, @session_key, Map.merge(fetch(get_session(conn)) || %{}, attribution))
    else
      _ -> conn
    end
  end

  defp store_marketing_attribution(conn, %{"fz_marketing" => allowed} = params)
       when allowed in ["true", "false"] do
    marketing = %{
      "marketing_allowed" => allowed == "true",
      "captured_at" => System.os_time(:second)
    }

    marketing =
      if allowed == "true" do
        Map.merge(marketing, click_references(params))
      else
        marketing
      end

    attribution = Map.put(fetch(get_session(conn)) || %{}, "marketing", marketing)
    put_session(conn, @session_key, attribution)
  end

  defp store_marketing_attribution(conn, _params), do: conn

  defp click_references(params) do
    Enum.reduce(@click_params, %{}, fn key, acc ->
      value = params["fz_" <> key]

      if is_binary(value) and byte_size(value) in 1..2048 do
        Map.put(acc, key, value)
      else
        acc
      end
    end)
  end

  defp valid_distinct_id(value) when is_binary(value) do
    case Ecto.UUID.cast(value) do
      {:ok, distinct_id} -> {:ok, distinct_id}
      :error -> :error
    end
  end

  defp valid_distinct_id(_value), do: :error

  defp valid_website_path("/" <> _rest = path) when byte_size(path) <= 512 do
    if String.contains?(path, ["?", "#", <<0>>]), do: :error, else: {:ok, path}
  end

  defp valid_website_path(_value), do: :error

  defp clean_request_target(conn) do
    query_string =
      conn.query_string
      |> URI.query_decoder()
      |> Enum.reject(fn {key, _value} -> key in [@distinct_id_param, @pathname_param] ++ @marketing_params end)
      |> URI.encode_query()

    if query_string == "" do
      conn.request_path
    else
      conn.request_path <> "?" <> query_string
    end
  end
end

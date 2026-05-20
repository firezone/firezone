defmodule PortalWeb.Cookie.PendingIdentity do
  @moduledoc """
  Cookie for OIDC pending identity verification state.
  """

  @enforce_keys [:pending_identity_id]
  defstruct [:pending_identity_id, params: %{}]

  @type t :: %__MODULE__{
          pending_identity_id: Ecto.UUID.t(),
          params: map()
        }

  @cookie_key_prefix "pending_identity_"

  def put(conn, %__MODULE__{} = cookie) do
    Plug.Conn.put_resp_cookie(conn, cookie_key(cookie.pending_identity_id), to_binary(cookie), cookie_options())
  end

  def delete(conn, %__MODULE__{} = cookie) do
    delete(conn, cookie.pending_identity_id)
  end

  def delete(conn, pending_identity_id) when is_binary(pending_identity_id) do
    Plug.Conn.delete_resp_cookie(conn, cookie_key(pending_identity_id), cookie_options())
  end

  def delete_all(conn, pending_identity_ids) do
    Enum.reduce(pending_identity_ids, conn, &delete(&2, &1))
  end

  def fetch(conn) do
    conn = Plug.Conn.fetch_query_params(conn)
    pending_identity_id = conn.params["pending_identity_id"] || conn.query_params["pending_identity_id"]

    fetch(conn, pending_identity_id)
  end

  def fetch(conn, pending_identity_id) when is_binary(pending_identity_id) do
    key = cookie_key(pending_identity_id)
    conn = Plug.Conn.fetch_cookies(conn, signed: [key])

    case from_binary(conn.cookies[key]) do
      %__MODULE__{pending_identity_id: ^pending_identity_id} = cookie -> cookie
      _ -> nil
    end
  end

  def fetch(_conn, _pending_identity_id), do: nil

  def fetch_state(conn) do
    case fetch(conn) do
      %__MODULE__{} = cookie ->
        Map.put(cookie.params, "pending_identity_id", cookie.pending_identity_id)

      nil ->
        %{}
    end
  end

  defp cookie_options do
    [
      sign: true,
      max_age: 15 * 60,
      same_site: "Lax",
      secure: Portal.Config.fetch_env!(:portal, :cookie_secure),
      http_only: true,
      signing_salt: Portal.Config.fetch_env!(:portal, :cookie_signing_salt)
    ]
  end

  defp cookie_key(pending_identity_id), do: @cookie_key_prefix <> pending_identity_id

  defp to_binary(%__MODULE__{} = cookie) do
    {Ecto.UUID.dump!(cookie.pending_identity_id), cookie.params || %{}}
    |> :erlang.term_to_binary()
  end

  defp from_binary(binary) when is_binary(binary) do
    case safe_binary_to_term(binary) do
      {pending_identity_id_bytes, params} when is_binary(pending_identity_id_bytes) ->
        with {:ok, pending_identity_id} <- Ecto.UUID.load(pending_identity_id_bytes) do
          %__MODULE__{pending_identity_id: pending_identity_id, params: normalize_params(params)}
        else
          _ -> nil
        end

      pending_identity_id_bytes when is_binary(pending_identity_id_bytes) ->
        with {:ok, pending_identity_id} <- Ecto.UUID.load(pending_identity_id_bytes) do
          %__MODULE__{pending_identity_id: pending_identity_id}
        else
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp from_binary(_), do: nil

  defp normalize_params(params) when is_map(params), do: params
  defp normalize_params(_params), do: %{}

  # sobelow_skip ["Misc.BinToTerm"]
  defp safe_binary_to_term(binary) do
    :erlang.binary_to_term(binary, [:safe])
  rescue
    _ -> :error
  end
end

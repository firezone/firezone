defmodule PortalWeb.Cookie.EmailOTP do
  @moduledoc """
  Cookie for email OTP authentication state.
  """

  @enforce_keys [:actor_id, :passcode_id, :email, :context_type]
  defstruct [:actor_id, :passcode_id, :email, :context_type]

  @type t :: %__MODULE__{
          actor_id: Ecto.UUID.t(),
          passcode_id: Ecto.UUID.t(),
          email: String.t(),
          context_type: :portal | :oauth | :gui_client | :headless_client
        }

  @cookie_key "email_otp"
  @cookie_options [
    encrypt: true,
    max_age: 15 * 60,
    same_site: "Lax",
    secure: Portal.Config.fetch_env!(:portal, :cookie_secure),
    http_only: true
  ]

  def put(conn, %__MODULE__{} = cookie) do
    Plug.Conn.put_resp_cookie(conn, @cookie_key, to_binary(cookie), @cookie_options)
  end

  def delete(conn) do
    Plug.Conn.delete_resp_cookie(conn, @cookie_key, @cookie_options)
  end

  @doc """
  Fetches email OTP state from the encrypted cookie.
  """
  def fetch(conn) do
    conn = Plug.Conn.fetch_cookies(conn, encrypted: [@cookie_key])
    from_binary(conn.cookies[@cookie_key])
  end

  @doc """
  Fetches email OTP state as a map for live_session.
  Used as a session function for the email_otp_verify live_session.
  """
  def fetch_state(conn) do
    case fetch(conn) do
      %__MODULE__{} = cookie ->
        %{"email" => cookie.email}

      nil ->
        %{}
    end
  end

  defp to_binary(%__MODULE__{
         actor_id: actor_id,
         passcode_id: passcode_id,
         email: email,
         context_type: context_type
       }) do
    {Ecto.UUID.dump!(actor_id), Ecto.UUID.dump!(passcode_id), email, context_type}
    |> :erlang.term_to_binary()
  end

  # sobelow_skip ["Misc.BinToTerm"]
  defp from_binary(binary) when is_binary(binary) do
    case :erlang.binary_to_term(binary, [:safe]) do
      {actor_id, passcode_id, email, context_type}
      when context_type in [:portal, :oauth, :gui_client, :headless_client] ->
        %__MODULE__{
          actor_id: Ecto.UUID.load!(actor_id),
          passcode_id: Ecto.UUID.load!(passcode_id),
          email: email,
          context_type: context_type
        }
    end
  rescue
    _ -> nil
  end

  defp from_binary(_), do: nil
end

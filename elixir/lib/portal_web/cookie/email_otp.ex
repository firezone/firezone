defmodule PortalWeb.Cookie.EmailOTP do
  @moduledoc """
  Cookie for email OTP authentication state.
  """

  @enforce_keys [:actor_id, :passcode_id, :email]
  defstruct [:actor_id, :passcode_id, :email]

  @type t :: %__MODULE__{
          actor_id: Ecto.UUID.t(),
          passcode_id: Ecto.UUID.t(),
          email: String.t()
        }

  @cookie_key "email_otp"
  @cookie_options [
    sign: true,
    max_age: 15 * 60,
    same_site: "Strict",
    secure: Portal.Config.fetch_env!(:portal, :cookie_secure),
    http_only: true,
    signing_salt: Portal.Config.fetch_env!(:portal, :cookie_signing_salt)
  ]

  def put(conn, %__MODULE__{} = cookie) do
    Plug.Conn.put_resp_cookie(conn, @cookie_key, to_binary(cookie), @cookie_options)
  end

  def delete(conn) do
    Plug.Conn.delete_resp_cookie(conn, @cookie_key, @cookie_options)
  end

  @doc """
  Fetches email OTP state from the signed cookie.
  """
  def fetch(conn) do
    conn = Plug.Conn.fetch_cookies(conn, signed: [@cookie_key])
    from_binary(conn.cookies[@cookie_key])
  end

  @doc """
  Fetches email OTP state as a map for live_session.
  Used as a session function for the email_otp_verify live_session.
  """
  def fetch_state(conn) do
    case fetch(conn) do
      %__MODULE__{} = cookie ->
        %{
          "actor_id" => cookie.actor_id,
          "one_time_passcode_id" => cookie.passcode_id,
          "email" => cookie.email
        }

      nil ->
        %{}
    end
  end

  defp to_binary(%__MODULE__{actor_id: actor_id, passcode_id: passcode_id, email: email}) do
    {Ecto.UUID.dump!(actor_id), Ecto.UUID.dump!(passcode_id), email}
    |> :erlang.term_to_binary()
  end

  defp from_binary(binary) when is_binary(binary) do
    {actor_id, passcode_id, email} = :erlang.binary_to_term(binary, [:safe])

    %__MODULE__{
      actor_id: Ecto.UUID.load!(actor_id),
      passcode_id: Ecto.UUID.load!(passcode_id),
      email: email
    }
  rescue
    _ -> nil
  end

  defp from_binary(_), do: nil
end

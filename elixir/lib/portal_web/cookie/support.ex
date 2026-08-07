defmodule PortalWeb.Cookie.Support do
  @moduledoc """
  Cookie for Firezone Support sign-in state.
  """

  @enforce_keys [:account_id, :email, :stage]
  defstruct [:account_id, :email, :stage, :challenge]

  @type t :: %__MODULE__{
          account_id: Ecto.UUID.t(),
          email: String.t(),
          stage: :otp | :passkey,
          challenge: Portal.Crypto.WebAuthn.Challenge.t() | nil
        }

  @cookie_key "fz_support"
  @cookie_options [
    sign: true,
    max_age: 15 * 60,
    same_site: "Lax",
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

  def fetch(conn) do
    conn = Plug.Conn.fetch_cookies(conn, signed: [@cookie_key])
    from_binary(conn.cookies[@cookie_key])
  end

  @doc """
  Fetches support sign-in state as a map for live_session.
  """
  def fetch_state(conn) do
    case fetch(conn) do
      %__MODULE__{} = cookie ->
        %{
          "support_account_id" => cookie.account_id,
          "support_email" => cookie.email,
          "support_stage" => Atom.to_string(cookie.stage),
          "support_challenge_bytes" => challenge_bytes(cookie.challenge),
          "support_credential_id" => challenge_credential_id(cookie.challenge)
        }

      nil ->
        %{}
    end
  end

  defp challenge_bytes(%Portal.Crypto.WebAuthn.Challenge{bytes: bytes}),
    do: Base.url_encode64(bytes, padding: false)

  defp challenge_bytes(_challenge), do: nil

  defp challenge_credential_id(%Portal.Crypto.WebAuthn.Challenge{
         allow_credentials: [{credential_id, _cose_key}]
       }),
       do: Base.url_encode64(credential_id, padding: false)

  defp challenge_credential_id(_challenge), do: nil

  defp to_binary(%__MODULE__{} = cookie) do
    {Ecto.UUID.dump!(cookie.account_id), cookie.email, cookie.stage, cookie.challenge}
    |> :erlang.term_to_binary()
  end

  # sobelow_skip ["Misc.BinToTerm"]
  defp from_binary(binary) when is_binary(binary) do
    {account_id, email, stage, challenge} = :erlang.binary_to_term(binary, [:safe])

    %__MODULE__{
      account_id: Ecto.UUID.load!(account_id),
      email: email,
      stage: stage,
      challenge: challenge
    }
  rescue
    _ -> nil
  end

  defp from_binary(_), do: nil
end

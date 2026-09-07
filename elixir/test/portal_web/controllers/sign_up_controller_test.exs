defmodule PortalWeb.SignUpControllerTest do
  use PortalWeb.ConnCase, async: true

  alias PortalWeb.Cookie
  alias PortalWeb.Mocks

  setup do
    Mocks.OIDC.stub_discovery_document()
    :ok
  end

  describe "google/2" do
    test "redirects to Google with an account picker and binds the state to a cookie", %{
      conn: conn
    } do
      mock_endpoint = Mocks.OIDC.mock_endpoint()

      Mocks.OIDC.override_google_auth_provider_config()

      conn = post(conn, ~p"/sign_up/google")

      redirect_url = redirected_to(conn)
      assert redirect_url =~ "#{mock_endpoint}/authorize"
      assert redirect_url =~ "prompt=select_account"
      assert redirect_url =~ "client_id=test-client"
      assert redirect_url =~ "code_challenge_method=S256"

      %{"state" => state, "nonce" => nonce} =
        redirect_url |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()

      assert {:ok, %{type: "google-sign-up", lv_pid: nil}} =
               PortalWeb.OIDC.verify_verification_state(state)

      assert %Cookie.SignUpState{state: ^state, verifier: verifier} =
               conn |> recycle() |> with_endpoint_key_base() |> Cookie.SignUpState.fetch()

      assert nonce == PortalWeb.OIDC.nonce(verifier)
    end

    test "redirects back to sign-up with an error when Google discovery fails", %{conn: conn} do
      Mocks.OIDC.stub_connection_refused()

      Mocks.OIDC.override_google_auth_provider_config()

      conn = post(conn, ~p"/sign_up/google")

      assert redirected_to(conn) == "/sign_up"
      assert flash(conn, :error) =~ "Google sign-in is unavailable right now"
    end
  end

  defp with_endpoint_key_base(conn) do
    Map.put(conn, :secret_key_base, PortalWeb.Endpoint.config(:secret_key_base))
  end
end

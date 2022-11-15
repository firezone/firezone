defmodule FzHttp.Conf.OIDCConfigTest do
  use FzHttp.DataCase, async: true

  alias FzHttp.Conf.OIDCConfig

  setup tags do
    pid = start_supervised!({OpenIDConnect.Worker, tags[:providers]})

    Map.merge(tags, %{pid: pid})
  end

  describe "end_session_uri/4" do
    @tag [
      expected: %{
        auth0: nil,
        okta: "https://okta",
        azure: "https://azure",
        google: nil,
        onelogin: "https://onelogin",
        keycloak: "https://keycloak"
      }
    ]
    test "builds the end_session_endpoint from the JSON", %{
      expected: expected,
      providers: providers
    } do
      for {p, conf} <- providers do
        assert Map.get(expected, p) ==
                 OpenIDConnect.end_session_uri(p, %{"id_token_hint" => "test"})
      end
    end
  end
end

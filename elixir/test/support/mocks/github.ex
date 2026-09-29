defmodule PortalWeb.Mocks.GitHub do
  @moduledoc """
  Req.Test stub for the GitHub OAuth token endpoint and the user API.

  ## Usage

      Mocks.GitHub.stub()

      Mocks.GitHub.stub(
        user: %{"id" => 42, "login" => "octocat"},
        emails: [%{"email" => "octocat@example.com", "primary" => true, "verified" => true}]
      )

      Mocks.GitHub.stub(token_response: {200, %{"error" => "bad_verification_code"}})

  Each token request is forwarded to the test process as
  `{:github_token_request, params}`, and each API request as
  `{:github_api_request, path, headers}`.
  """

  @default_user %{
    "id" => 583_231,
    "login" => "octocat",
    "name" => "The Octocat",
    "html_url" => "https://github.com/octocat",
    "avatar_url" => "https://avatars.githubusercontent.com/u/583231"
  }

  @default_emails [
    %{
      "email" => "octocat@example.com",
      "primary" => true,
      "verified" => true,
      "visibility" => "public"
    }
  ]

  def default_user, do: @default_user

  def stub(opts \\ []) do
    test_pid = self()
    user = Keyword.get(opts, :user, @default_user)
    emails = Keyword.get(opts, :emails, @default_emails)

    token_response =
      Keyword.get(opts, :token_response, {200, %{"access_token" => "gho_test", "scope" => ""}})

    Req.Test.stub(PortalWeb.GitHub, fn conn ->
      case {conn.method, conn.request_path} do
        {"POST", "/login/oauth/access_token"} ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          send(test_pid, {:github_token_request, URI.decode_query(body)})
          {status, response} = token_response
          Req.Test.json(Plug.Conn.put_status(conn, status), response)

        {"GET", "/user" = path} ->
          send_api_request(test_pid, conn, path)
          Req.Test.json(conn, user)

        {"GET", "/user/emails" = path} ->
          send_api_request(test_pid, conn, path)
          Req.Test.json(conn, emails)
      end
    end)
  end

  defp send_api_request(test_pid, conn, path) do
    headers = Map.new(["authorization", "x-github-api-version"], &{&1, Plug.Conn.get_req_header(conn, &1)})
    send(test_pid, {:github_api_request, path, headers})
  end
end

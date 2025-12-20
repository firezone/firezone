defmodule Web.LiveHooks.RedirectIfAuthenticatedTest do
  use Web.ConnCase, async: true

  import Domain.AccountFixtures
  import Domain.SubjectFixtures

  alias Web.LiveHooks.RedirectIfAuthenticated

  setup do
    account = account_fixture()

    {:ok, account: account}
  end

  defp build_socket(assigns) do
    %Phoenix.LiveView.Socket{
      assigns: Map.merge(%{__changed__: %{}}, assigns)
    }
  end

  describe "on_mount/4" do
    test "halts and redirects authenticated user when not signing in as client", %{
      account: account
    } do
      subject = admin_subject_fixture(account: account)
      socket = build_socket(%{account: account, subject: subject})

      assert {:halt, redirected_socket} =
               RedirectIfAuthenticated.on_mount(:default, %{}, %{}, socket)

      expected_path = "/#{account.slug}/sites"
      assert {:redirect, %{to: ^expected_path}} = redirected_socket.redirected
    end

    test "continues when as=client param is set even with authenticated user", %{
      account: account
    } do
      subject = admin_subject_fixture(account: account)
      socket = build_socket(%{account: account, subject: subject})

      assert {:cont, returned_socket} =
               RedirectIfAuthenticated.on_mount(:default, %{"as" => "client"}, %{}, socket)

      assert is_nil(returned_socket.redirected)
    end

    test "continues when user is not authenticated", %{account: account} do
      socket = build_socket(%{account: account})

      assert {:cont, returned_socket} =
               RedirectIfAuthenticated.on_mount(:default, %{}, %{}, socket)

      assert is_nil(returned_socket.redirected)
    end

    test "continues when no account is assigned" do
      socket = build_socket(%{})

      assert {:cont, returned_socket} =
               RedirectIfAuthenticated.on_mount(:default, %{}, %{}, socket)

      assert is_nil(returned_socket.redirected)
    end

    test "integration: LiveView with as=client does not redirect authenticated user", %{
      conn: conn,
      account: account
    } do
      # Create an authenticated admin actor
      actor = Domain.ActorFixtures.admin_actor_fixture(account: account)

      # Authenticate and mount LiveView with as=client
      {:ok, _view, html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account.slug}?as=client&nonce=test-nonce&state=test-state")

      # Should render the sign-in page, not redirect to /sites
      assert html =~ "Sign In"
    end

    test "integration: LiveView without as=client redirects authenticated user to portal", %{
      conn: conn,
      account: account
    } do
      # Create an authenticated admin actor
      actor = Domain.ActorFixtures.admin_actor_fixture(account: account)

      # Authenticate and try to mount LiveView without as=client
      {:error, {:redirect, %{to: redirect_path}}} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account.slug}")

      # Should redirect to /sites (portal)
      assert redirect_path == ~p"/#{account.slug}/sites"
    end
  end
end

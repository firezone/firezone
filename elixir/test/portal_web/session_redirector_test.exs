defmodule PortalWeb.Session.RedirectorTest do
  use ExUnit.Case, async: true

  alias PortalWeb.Session.Redirector

  describe "sanitize_redirect_to/3" do
    setup do
      account = %Portal.Account{id: Ecto.UUID.generate(), slug: "acme"}
      other_account = %Portal.Account{id: Ecto.UUID.generate(), slug: "other_acme"}

      {:ok, account: account, other_account: other_account}
    end

    test "allows paths scoped to the account slug", %{account: account} do
      assert Redirector.sanitize_redirect_to(account, "/acme/sites") == "/acme/sites"
      assert Redirector.sanitize_redirect_to(account, "/acme?tab=sites") == "/acme?tab=sites"
    end

    test "allows paths scoped to the account id", %{account: account} do
      redirect_to = "/#{account.id}/resources?site_id=123"

      assert Redirector.sanitize_redirect_to(account, redirect_to) == redirect_to
    end

    test "rejects paths scoped to another account", %{
      account: account,
      other_account: other_account
    } do
      assert Redirector.sanitize_redirect_to(account, "/#{other_account.slug}/sites") ==
               "/#{account.slug}/sites"

      assert Redirector.sanitize_redirect_to(account, "/#{other_account.id}/sites") ==
               "/#{account.slug}/sites"
    end

    test "rejects paths whose first segment only prefixes the account slug or id", %{
      account: account
    } do
      assert Redirector.sanitize_redirect_to(account, "/acme_other/sites") ==
               "/#{account.slug}/sites"

      assert Redirector.sanitize_redirect_to(account, "/#{account.id}0/sites") ==
               "/#{account.slug}/sites"
    end

    test "rejects external, protocol-relative, and malformed redirect targets", %{account: account} do
      assert Redirector.sanitize_redirect_to(account, "https://example.com/#{account.slug}/sites") ==
               "/#{account.slug}/sites"

      assert Redirector.sanitize_redirect_to(account, "//#{account.slug}/sites") ==
               "/#{account.slug}/sites"

      assert Redirector.sanitize_redirect_to(account, "/") == "/#{account.slug}/sites"
    end
  end
end

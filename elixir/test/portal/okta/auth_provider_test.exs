defmodule Portal.Okta.AuthProviderTest do
  use Portal.DataCase, async: true

  import Ecto.Changeset
  import Portal.AuthProviderFixtures

  alias Portal.Okta.AuthProvider

  defp build_changeset(attrs) do
    %AuthProvider{}
    |> cast(
      attrs,
      [:name, :context, :okta_domain, :client_id, :client_secret, :issuer, :is_verified]
    )
    |> AuthProvider.changeset()
  end

  describe "changeset/1 basic validations" do
    test "inserts okta_domain at maximum length" do
      domain = String.duplicate("a", 251) <> ".com"
      provider = okta_provider_fixture(okta_domain: domain, issuer: "https://#{domain}")
      assert String.length(provider.okta_domain) == 255
    end

    test "rejects okta_domain exceeding maximum length" do
      changeset = build_changeset(%{okta_domain: String.duplicate("a", 256)})
      assert %{okta_domain: ["should be at most 255 character(s)"]} = errors_on(changeset)
    end

    test "inserts issuer at maximum length" do
      provider = okta_provider_fixture(issuer: String.duplicate("a", 2000))
      assert String.length(provider.issuer) == 2000
    end

    test "rejects issuer exceeding maximum length" do
      changeset = build_changeset(%{issuer: String.duplicate("a", 2001)})
      assert "should be at most 2000 character(s)" in errors_on(changeset).issuer
    end

    test "inserts client_id at maximum length" do
      provider = okta_provider_fixture(client_id: String.duplicate("a", 255))
      assert String.length(provider.client_id) == 255
    end

    test "rejects client_id exceeding maximum length" do
      changeset = build_changeset(%{client_id: String.duplicate("a", 256)})
      assert %{client_id: ["should be at most 255 character(s)"]} = errors_on(changeset)
    end

    test "inserts client_secret at maximum length" do
      provider = okta_provider_fixture(client_secret: String.duplicate("a", 255))
      assert String.length(provider.client_secret) == 255
    end

    test "rejects client_secret exceeding maximum length" do
      changeset = build_changeset(%{client_secret: String.duplicate("a", 256)})
      assert %{client_secret: ["should be at most 255 character(s)"]} = errors_on(changeset)
    end
  end
end

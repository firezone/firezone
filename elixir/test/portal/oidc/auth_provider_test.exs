defmodule Portal.OIDC.AuthProviderTest do
  use Portal.DataCase, async: true

  import Ecto.Changeset
  import Portal.AuthProviderFixtures

  alias Portal.OIDC.AuthProvider

  defp build_changeset(attrs) do
    %AuthProvider{}
    |> cast(
      attrs,
      [
        :name,
        :context,
        :client_id,
        :client_secret,
        :discovery_document_uri,
        :issuer,
        :is_verified
      ]
    )
    |> AuthProvider.changeset()
  end

  describe "changeset/1 basic validations" do
    test "inserts client_id at maximum length" do
      provider = oidc_provider_fixture(client_id: String.duplicate("a", 255))
      assert String.length(provider.client_id) == 255
    end

    test "rejects client_id exceeding maximum length" do
      changeset = build_changeset(%{client_id: String.duplicate("a", 256)})
      assert %{client_id: ["should be at most 255 character(s)"]} = errors_on(changeset)
    end

    test "inserts client_secret at maximum length" do
      provider = oidc_provider_fixture(client_secret: String.duplicate("a", 255))
      assert String.length(provider.client_secret) == 255
    end

    test "rejects client_secret exceeding maximum length" do
      changeset = build_changeset(%{client_secret: String.duplicate("a", 256)})
      assert %{client_secret: ["should be at most 255 character(s)"]} = errors_on(changeset)
    end

    test "inserts discovery_document_uri at maximum length" do
      uri = "https://" <> String.duplicate("a", 1992)
      provider = oidc_provider_fixture(discovery_document_uri: uri)
      assert String.length(provider.discovery_document_uri) == 2000
    end

    test "rejects discovery_document_uri exceeding maximum length" do
      uri = "https://" <> String.duplicate("a", 1993)
      changeset = build_changeset(%{discovery_document_uri: uri})

      assert %{discovery_document_uri: ["should be at most 2000 character(s)"]} =
               errors_on(changeset)
    end

    test "inserts issuer at maximum length" do
      provider = oidc_provider_fixture(issuer: String.duplicate("a", 2000))
      assert String.length(provider.issuer) == 2000
    end

    test "rejects issuer exceeding maximum length" do
      changeset = build_changeset(%{issuer: String.duplicate("a", 2001)})
      assert %{issuer: ["should be at most 2000 character(s)"]} = errors_on(changeset)
    end
  end
end

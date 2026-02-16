defmodule Portal.Google.AuthProviderTest do
  use Portal.DataCase, async: true

  import Portal.AccountFixtures
  import Portal.AuthProviderFixtures

  alias Portal.Google.AuthProvider

  describe "changeset/1" do
    setup do
      account = account_fixture()

      %{account: account}
    end

    test "validates required fields", %{account: account} do
      changeset =
        %AuthProvider{account_id: account.id}
        |> Ecto.Changeset.cast(%{}, [:name, :context, :issuer, :is_verified])
        |> AuthProvider.changeset()

      refute changeset.valid?
      # name and context have defaults, so they won't be blank
      # issuer is required
      assert "can't be blank" in errors_on(changeset).issuer
      # is_verified must be explicitly accepted (true)
      assert "must be accepted" in errors_on(changeset).is_verified
    end

    test "validates is_verified must be true", %{account: account} do
      changeset =
        %AuthProvider{account_id: account.id}
        |> Ecto.Changeset.cast(
          %{
            name: "Test Google",
            context: :clients_and_portal,
            issuer: "https://accounts.google.com",
            is_verified: false
          },
          [:name, :context, :issuer, :is_verified]
        )
        |> AuthProvider.changeset()

      refute changeset.valid?
      assert "must be accepted" in errors_on(changeset).is_verified
    end

    test "validates issuer length constraints", %{account: account} do
      # Test empty string shows can't be blank (not length error)
      changeset =
        %AuthProvider{account_id: account.id}
        |> Ecto.Changeset.cast(
          %{
            name: "Test Google",
            context: :clients_and_portal,
            issuer: "",
            is_verified: true
          },
          [:name, :context, :issuer, :is_verified]
        )
        |> AuthProvider.changeset()

      refute changeset.valid?
      assert "can't be blank" in errors_on(changeset).issuer

      # Test maximum length (> 2000)
      long_issuer = String.duplicate("a", 2001)

      changeset =
        %AuthProvider{account_id: account.id}
        |> Ecto.Changeset.cast(
          %{
            name: "Test Google",
            context: :clients_and_portal,
            issuer: long_issuer,
            is_verified: true
          },
          [:name, :context, :issuer, :is_verified]
        )
        |> AuthProvider.changeset()

      refute changeset.valid?
      assert "should be at most 2000 character(s)" in errors_on(changeset).issuer
    end

    test "inserts issuer at maximum length", %{account: account} do
      provider =
        google_provider_fixture(
          account: account,
          issuer: String.duplicate("a", 2000)
        )

      assert String.length(provider.issuer) == 2000
    end

    test "validates portal_session_lifetime_secs range", %{account: account} do
      # Test below minimum (< 300)
      changeset =
        %AuthProvider{account_id: account.id}
        |> Ecto.Changeset.cast(
          %{
            name: "Test Google",
            context: :portal_only,
            issuer: "https://accounts.google.com",
            is_verified: true,
            portal_session_lifetime_secs: 299
          },
          [:name, :context, :issuer, :is_verified, :portal_session_lifetime_secs]
        )
        |> AuthProvider.changeset()

      refute changeset.valid?

      assert "must be greater than or equal to 300" in errors_on(changeset).portal_session_lifetime_secs

      # Test above maximum (> 86400)
      changeset =
        %AuthProvider{account_id: account.id}
        |> Ecto.Changeset.cast(
          %{
            name: "Test Google",
            context: :portal_only,
            issuer: "https://accounts.google.com",
            is_verified: true,
            portal_session_lifetime_secs: 86_401
          },
          [:name, :context, :issuer, :is_verified, :portal_session_lifetime_secs]
        )
        |> AuthProvider.changeset()

      refute changeset.valid?

      assert "must be less than or equal to 86400" in errors_on(changeset).portal_session_lifetime_secs
    end

    test "validates client_session_lifetime_secs range", %{account: account} do
      # Test below minimum (< 3600)
      changeset =
        %AuthProvider{account_id: account.id}
        |> Ecto.Changeset.cast(
          %{
            name: "Test Google",
            context: :clients_only,
            issuer: "https://accounts.google.com",
            is_verified: true,
            client_session_lifetime_secs: 3599
          },
          [:name, :context, :issuer, :is_verified, :client_session_lifetime_secs]
        )
        |> AuthProvider.changeset()

      refute changeset.valid?

      assert "must be greater than or equal to 3600" in errors_on(changeset).client_session_lifetime_secs

      # Test above maximum (> 7776000)
      changeset =
        %AuthProvider{account_id: account.id}
        |> Ecto.Changeset.cast(
          %{
            name: "Test Google",
            context: :clients_only,
            issuer: "https://accounts.google.com",
            is_verified: true,
            client_session_lifetime_secs: 7_776_001
          },
          [:name, :context, :issuer, :is_verified, :client_session_lifetime_secs]
        )
        |> AuthProvider.changeset()

      refute changeset.valid?

      assert "must be less than or equal to 7776000" in errors_on(changeset).client_session_lifetime_secs
    end

    test "validates context enum values", %{account: account} do
      valid_contexts = [:clients_and_portal, :clients_only, :portal_only]

      for context <- valid_contexts do
        changeset =
          %AuthProvider{account_id: account.id}
          |> Ecto.Changeset.cast(
            %{
              name: "Test Google",
              context: context,
              issuer: "https://accounts.google.com",
              is_verified: true
            },
            [:name, :context, :issuer, :is_verified]
          )
          |> AuthProvider.changeset()

        assert changeset.valid?, "Expected context #{context} to be valid"
      end

      # Test invalid context
      changeset =
        %AuthProvider{account_id: account.id}
        |> Ecto.Changeset.cast(
          %{
            name: "Test Google",
            context: :invalid_context,
            issuer: "https://accounts.google.com",
            is_verified: true
          },
          [:name, :context, :issuer, :is_verified]
        )
        |> AuthProvider.changeset()

      refute changeset.valid?
      assert "is invalid" in errors_on(changeset).context
    end

    test "accepts valid changeset with all required fields", %{account: account} do
      changeset =
        %AuthProvider{account_id: account.id}
        |> Ecto.Changeset.cast(
          %{
            name: "Test Google",
            context: :clients_and_portal,
            issuer: "https://accounts.google.com",
            is_verified: true,
            portal_session_lifetime_secs: 28_800,
            client_session_lifetime_secs: 604_800
          },
          [
            :name,
            :context,
            :issuer,
            :is_verified,
            :portal_session_lifetime_secs,
            :client_session_lifetime_secs
          ]
        )
        |> AuthProvider.changeset()

      assert changeset.valid?
    end

    test "sets default values", %{account: account} do
      changeset =
        %AuthProvider{account_id: account.id}
        |> Ecto.Changeset.cast(
          %{
            issuer: "https://accounts.google.com",
            is_verified: true
          },
          [:issuer, :is_verified]
        )
        |> AuthProvider.changeset()

      # Default values from schema
      assert Ecto.Changeset.get_field(changeset, :name) == "Google"
      assert Ecto.Changeset.get_field(changeset, :context) == :clients_and_portal
      assert Ecto.Changeset.get_field(changeset, :is_verified) == true
    end
  end

  describe "default_portal_session_lifetime_secs/0" do
    test "returns the default portal session lifetime" do
      assert AuthProvider.default_portal_session_lifetime_secs() == 28_800
    end
  end

  describe "default_client_session_lifetime_secs/0" do
    test "returns the default client session lifetime" do
      assert AuthProvider.default_client_session_lifetime_secs() == 604_800
    end
  end
end

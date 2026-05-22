defmodule PortalWeb.OIDC.IdentityProfileTest do
  use ExUnit.Case, async: true

  alias PortalWeb.OIDC.IdentityProfile

  @account_id Ecto.UUID.generate()

  @valid_claims %{
    "email" => "user@example.com",
    "email_verified" => true,
    "oid" => "object-id-123",
    "sub" => "sub-id-456",
    "iss" => "https://login.microsoftonline.com/tenant/v2.0",
    "name" => "Test User",
    "aud" => "client-id",
    "exp" => 9_999_999_999
  }

  describe "build/4 without email_claim (non-Entra providers)" do
    test "uses email claim when present and valid" do
      assert {:ok, profile} = IdentityProfile.build(@valid_claims, %{}, @account_id)
      assert profile.email == "user@example.com"
    end

    test "returns error when email is nil" do
      claims = Map.delete(@valid_claims, "email")

      assert {:error, changeset} = IdentityProfile.build(claims, %{}, @account_id)
      assert "can't be blank" in errors_on(changeset).email
    end

    test "returns error when email is not a valid email" do
      claims = Map.put(@valid_claims, "email", "not-an-email")

      assert {:error, changeset} = IdentityProfile.build(claims, %{}, @account_id)
      assert "is an invalid email address" in errors_on(changeset).email
    end
  end

  describe "build/4 with email_claim (Entra providers)" do
    test "uses configured upn claim" do
      claims = Map.put(@valid_claims, "upn", "user@contoso.com")

      assert {:ok, profile} =
               IdentityProfile.build(claims, %{}, @account_id, email_claim: "upn")

      assert profile.email == "user@contoso.com"
    end

    test "uses configured email claim" do
      assert {:ok, profile} =
               IdentityProfile.build(@valid_claims, %{}, @account_id, email_claim: "email")

      assert profile.email == "user@example.com"
    end

    test "uses configured preferred_username claim" do
      claims = Map.put(@valid_claims, "preferred_username", "user@contoso.com")

      assert {:ok, profile} =
               IdentityProfile.build(claims, %{}, @account_id, email_claim: "preferred_username")

      assert profile.email == "user@contoso.com"
    end

    test "returns error when configured claim is missing" do
      claims = Map.delete(@valid_claims, "upn")

      assert {:error, changeset} =
               IdentityProfile.build(claims, %{}, @account_id, email_claim: "upn")

      assert "can't be blank" in errors_on(changeset).email
    end

    test "returns error when configured claim is not a valid email" do
      claims = Map.put(@valid_claims, "upn", "jsmith_partner.com#EXT#@tenant")

      assert {:error, changeset} =
               IdentityProfile.build(claims, %{}, @account_id, email_claim: "upn")

      assert "is an invalid email address" in errors_on(changeset).email
    end

    test "does not fall back to other claims when configured claim is invalid" do
      claims =
        @valid_claims
        |> Map.put("upn", "not-valid")
        |> Map.put("email", "valid@example.com")

      assert {:error, _changeset} =
               IdentityProfile.build(claims, %{}, @account_id, email_claim: "upn")
    end
  end

  describe "build/4 idp_id" do
    test "prefers oid over sub" do
      assert {:ok, profile} = IdentityProfile.build(@valid_claims, %{}, @account_id)
      assert profile.idp_id == "object-id-123"
    end

    test "falls back to sub when oid is nil" do
      claims = Map.delete(@valid_claims, "oid")

      assert {:ok, profile} = IdentityProfile.build(claims, %{}, @account_id)
      assert profile.idp_id == "sub-id-456"
    end
  end

  describe "build/4 email_verified" do
    test "requires boolean true from claims or userinfo" do
      claims =
        @valid_claims
        |> Map.put("email_verified", "true")

      assert {:ok, profile} = IdentityProfile.build(claims, %{}, @account_id)
      assert profile.email_verified == :unverified

      claims = Map.delete(@valid_claims, "email_verified")
      userinfo = %{
        "sub" => @valid_claims["sub"],
        "email" => @valid_claims["email"],
        "email_verified" => "true"
      }

      assert {:ok, profile} = IdentityProfile.build(claims, userinfo, @account_id)
      assert profile.email_verified == :unverified

      userinfo = %{
        "sub" => @valid_claims["sub"],
        "email" => @valid_claims["email"],
        "email_verified" => true
      }

      assert {:ok, profile} = IdentityProfile.build(claims, userinfo, @account_id)
      assert profile.email_verified == :verified
    end

    test "does not trust userinfo when ID token email_verified is non-boolean" do
      claims =
        @valid_claims
        |> Map.put("email_verified", "false")

      assert {:ok, profile} =
               IdentityProfile.build(
                 claims,
                 %{
                   "sub" => @valid_claims["sub"],
                   "email" => @valid_claims["email"],
                   "email_verified" => true
                 },
                 @account_id
               )

      assert profile.email_verified == :unverified
    end

    test "treats userinfo email_verified as missing when subjects differ" do
      claims = Map.delete(@valid_claims, "email_verified")

      userinfo = %{
        "sub" => "different-subject",
        "email" => @valid_claims["email"],
        "email_verified" => true
      }

      assert {:ok, profile} = IdentityProfile.build(claims, userinfo, @account_id)
      assert profile.email_verified == :missing
    end

    test "reports :missing when neither claims nor userinfo set email_verified" do
      claims = Map.delete(@valid_claims, "email_verified")

      assert {:ok, profile} = IdentityProfile.build(claims, %{}, @account_id)
      assert profile.email_verified == :missing
    end

    test "trusts userinfo email_verified when userinfo omits email and subject matches" do
      claims = Map.delete(@valid_claims, "email_verified")

      userinfo = %{
        "sub" => @valid_claims["sub"],
        "email_verified" => true
      }

      assert {:ok, profile} = IdentityProfile.build(claims, userinfo, @account_id)
      assert profile.email_verified == :verified
    end

    test "ignores profile attrs from mismatched userinfo" do
      userinfo = %{
        "sub" => "different-subject",
        "email" => @valid_claims["email"],
        "email_verified" => true,
        "name" => "Different User"
      }

      assert {:ok, profile} = IdentityProfile.build(@valid_claims, userinfo, @account_id)

      assert profile.email_verified == :verified
      assert profile.profile_attrs["name"] == @valid_claims["name"]
    end
  end

  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end

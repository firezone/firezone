defmodule PortalWeb.OIDC.IdentityProfile do
  @moduledoc false

  import Ecto.Changeset

  alias Portal.ExternalIdentity

  @idp_fields ~w[
    email
    issuer
    idp_id
    name
    given_name
    family_name
    middle_name
    nickname
    preferred_username
    profile
    picture
  ]a

  @type t :: %{
          email: String.t() | nil,
          idp_id: String.t() | nil,
          issuer: String.t() | nil,
          profile_attrs: map(),
          email_verified: boolean()
        }

  @spec build(map(), map(), Ecto.UUID.t()) :: {:ok, t()} | {:error, Ecto.Changeset.t()}
  def build(claims, userinfo, account_id) do
    email = claims["email"]
    idp_id = claims["oid"] || claims["sub"]
    issuer = claims["iss"]
    profile_attrs = extract_profile_attrs(claims, userinfo)

    attrs =
      profile_attrs
      |> Map.put("account_id", account_id)
      |> Map.put("email", email)
      |> Map.put("issuer", issuer)
      |> Map.put("idp_id", idp_id)

    case validate_upsert_attrs(attrs) do
      %{valid?: true} ->
        {:ok,
         %{
           email: email,
           idp_id: idp_id,
           issuer: issuer,
           profile_attrs: profile_attrs,
           email_verified: email_verified?(claims, userinfo)
         }}

      changeset ->
        {:error, changeset}
    end
  end

  defp email_verified?(claims, userinfo) do
    (claims["email_verified"] || userinfo["email_verified"]) == true
  end

  defp validate_upsert_attrs(attrs) do
    %ExternalIdentity{}
    |> cast(attrs, @idp_fields ++ ~w[account_id actor_id]a)
    |> validate_required(~w[email issuer idp_id name account_id]a)
    |> validate_length(:email, max: 255)
    |> validate_length(:issuer, max: 2048)
    |> validate_length(:idp_id, max: 255)
    |> validate_length(:name, max: 255)
    |> validate_length(:given_name, max: 255)
    |> validate_length(:family_name, max: 255)
    |> validate_length(:middle_name, max: 255)
    |> validate_length(:nickname, max: 255)
    |> validate_length(:preferred_username, max: 255)
    |> validate_length(:profile, max: 2048)
    |> validate_length(:picture, max: 2048)
  end

  defp extract_profile_attrs(claims, userinfo) do
    Map.merge(claims, userinfo)
    |> Map.take([
      "email",
      "name",
      "given_name",
      "family_name",
      "middle_name",
      "nickname",
      "preferred_username",
      "profile",
      "picture"
    ])
    |> sanitize_string_fields()
    |> maybe_populate_name()
  end

  # Ensure all profile fields are strings or nil - some IdPs may return unexpected types
  defp sanitize_string_fields(attrs) do
    Map.new(attrs, fn {k, v} -> {k, if(is_binary(v), do: v, else: nil)} end)
  end

  defp maybe_populate_name(attrs) do
    name =
      with nil <- present(attrs["name"]),
           nil <- given_family_name(attrs["given_name"], attrs["family_name"]),
           nil <- present(attrs["preferred_username"]),
           nil <- present(attrs["nickname"]) do
        attrs["email"]
      end

    Map.put(attrs, "name", name)
  end

  defp present(nil), do: nil
  defp present(s), do: if(String.trim(s) == "", do: nil, else: s)

  defp given_family_name(given, family) do
    case {present(given), present(family)} do
      {nil, nil} -> nil
      {g, nil} -> g
      {nil, f} -> f
      {g, f} -> "#{g} #{f}"
    end
  end
end

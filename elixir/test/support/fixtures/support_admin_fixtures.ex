defmodule Portal.SupportAdminFixtures do
  @moduledoc """
  Test helpers for creating support admins.
  """

  def valid_support_admin_attrs(attrs \\ %{}) do
    unique_num = System.unique_integer([:positive, :monotonic])
    Enum.into(attrs, %{email: "support.admin.#{unique_num}+firezone-support@firezone.dev"})
  end

  def support_admin_fixture(attrs \\ %{}) do
    attrs = attrs |> Enum.into(%{}) |> valid_support_admin_attrs()

    %Portal.SupportAdmin{}
    |> Ecto.Changeset.cast(attrs, [
      :email,
      :passkey_credential_id,
      :passkey_public_key,
      :passkey_sign_count,
      :passkey_registered_at,
      :registration_token_hash,
      :registration_token_expires_at,
      :otp_code_hash,
      :otp_expires_at,
      :otp_attempts
    ])
    |> Portal.SupportAdmin.changeset()
    |> Portal.Repo.insert!()
  end

  @doc """
  Creates a support admin with a pending registration link. Returns the admin
  and the raw registration token.
  """
  def provisioned_support_admin_fixture(attrs \\ %{}) do
    token = Portal.Crypto.random_token(32)

    expires_at =
      DateTime.add(
        DateTime.utc_now(),
        Portal.SupportAdmin.registration_token_lifetime_secs(),
        :second
      )

    support_admin =
      attrs
      |> Enum.into(%{})
      |> Map.put_new(:registration_token_hash, Portal.Crypto.hash(:sha256, token))
      |> Map.put_new(:registration_token_expires_at, expires_at)
      |> support_admin_fixture()

    {support_admin, token}
  end

  @doc """
  Creates a support admin with a registered passkey. Returns the admin and the
  software authenticator holding the private key.
  """
  def registered_support_admin_fixture(attrs \\ %{}) do
    authenticator = Portal.WebAuthnFixtures.generate_authenticator()

    support_admin =
      attrs
      |> Enum.into(%{})
      |> Map.put_new(:passkey_credential_id, authenticator.credential_id)
      |> Map.put_new(:passkey_public_key, :erlang.term_to_binary(authenticator.cose_key))
      |> Map.put_new(:passkey_sign_count, 0)
      |> Map.put_new(:passkey_registered_at, DateTime.utc_now())
      |> support_admin_fixture()

    {support_admin, authenticator}
  end
end

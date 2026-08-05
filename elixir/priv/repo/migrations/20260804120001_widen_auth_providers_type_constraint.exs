defmodule Portal.Repo.Migrations.WidenAuthProvidersTypeConstraint do
  use Ecto.Migration

  def up do
    drop(constraint(:auth_providers, :type_must_be_valid))

    create(
      constraint(:auth_providers, :type_must_be_valid,
        check:
          "type IN ('google', 'entra', 'okta', 'email_otp', 'oidc', 'userpass', 'firezone_support')"
      )
    )
  end

  def down do
    drop(constraint(:auth_providers, :type_must_be_valid))

    create(
      constraint(:auth_providers, :type_must_be_valid,
        check: "type IN ('google', 'entra', 'okta', 'email_otp', 'oidc', 'userpass')"
      )
    )
  end
end

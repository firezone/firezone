defmodule Portal.Repo.Migrations.ConstrainTypeOnTokens do
  use Ecto.Migration

  def change do
    create(
      constraint(:tokens, :type_must_be_valid,
        check: "type IN ('browser', 'client', 'api_client', 'relay', 'site', 'email')"
      )
    )
  end
end

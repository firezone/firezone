defmodule Domain.Repo.Migrations.AddInternetResources do
  use Ecto.Migration

  def change do
    execute("ALTER TABLE resources ALTER COLUMN address DROP NOT NULL")

    execute("""
    ALTER TABLE resources
    ADD CONSTRAINT require_resources_address CHECK (
      (type IN ('cidr', 'ip', 'dns') AND address IS NOT NULL)
      OR (type = 'internet' AND address IS NULL)
    );
    """)

    alter table(:policies) do
      add(:options, :map, default: %{})
    end

    # Manual migration that needs to be run after deployment
    # Domain.Accounts.Account.Query.not_deleted()
    # |> Domain.Repo.all()
    # |> Enum.each(fn account ->
    #   Domain.Resources.create_internet_resource(account)
    # end)
  end
end

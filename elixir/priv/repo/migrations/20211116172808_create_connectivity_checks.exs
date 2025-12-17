defmodule Portal.Repo.Migrations.CreateConnectivityChecks do
  use Ecto.Migration

  def change do
    create table(:connectivity_checks) do
      add(:url, :string)
      add(:response_body, :string)
      add(:response_code, :integer)
      add(:response_headers, :map)

      timestamps(type: :utc_datetime_usec)
    end

    create(index(:connectivity_checks, :inserted_at))
  end
end

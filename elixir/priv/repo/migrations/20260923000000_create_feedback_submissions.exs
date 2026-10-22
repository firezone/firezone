defmodule Portal.Repo.Migrations.CreateFeedbackSubmissions do
  use Ecto.Migration

  def change do
    create table(:feedback_submissions, primary_key: false) do
      add(:account_id, references(:accounts, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(:inserted_at, :timestamptz, null: false)
    end
  end
end

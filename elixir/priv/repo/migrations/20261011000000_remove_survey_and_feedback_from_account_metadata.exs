defmodule Portal.Repo.Migrations.RemoveSurveyAndFeedbackFromAccountMetadata do
  use Ecto.Migration

  def up do
    execute("""
    UPDATE accounts
    SET metadata = metadata - 'sign_up_survey' - 'deletion_feedback'
    WHERE metadata ?| array['sign_up_survey', 'deletion_feedback']
    """)
  end

  # The removed answers cannot be restored.
  def down, do: :ok
end

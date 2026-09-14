defmodule Portal.ObanFixtures do
  @moduledoc """
  Oban job rows in states the test helpers cannot put them in.
  """

  import Ecto.Query

  @doc """
  Inserts the job and marks it executing the way Oban's fetch does, with the
  given `attempted_at` and `attempted_by`.
  """
  def executing_job(changeset, opts \\ []) do
    job = Oban.insert!(changeset)

    Portal.Repo.update_all(
      from(j in Oban.Job, where: j.id == ^job.id),
      set: [
        state: "executing",
        attempt: 1,
        attempted_at: Keyword.get(opts, :attempted_at, DateTime.utc_now()),
        attempted_by: Keyword.get(opts, :attempted_by, ["portal@here", "uuid"])
      ]
    )

    Portal.Repo.get!(Oban.Job, job.id)
  end
end

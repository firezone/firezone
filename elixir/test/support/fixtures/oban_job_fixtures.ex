defmodule Portal.ObanJobFixtures do
  @moduledoc false

  import Ecto.Query

  alias Oban.Job
  alias Portal.Repo

  def jobs_for_worker(worker) do
    from(j in Job,
      where: j.worker == ^worker,
      order_by: [asc: j.inserted_at]
    )
    |> Repo.all()
  end

  def jobs_for_worker_and_arg(worker, arg_key, arg_value) do
    from(j in Job,
      where: j.worker == ^worker,
      where: fragment("?->>? = ?", j.args, ^arg_key, ^arg_value),
      order_by: [asc: j.inserted_at]
    )
    |> Repo.all()
  end
end

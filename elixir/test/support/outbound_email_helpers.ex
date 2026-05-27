defmodule Portal.OutboundEmailTestHelpers do
  @moduledoc false

  import Ecto.Query
  import ExUnit.Assertions, only: [assert: 1]

  alias Portal.Repo

  def collect_queued_emails(account_id) do
    [worker: Portal.Workers.OutboundEmail, args: %{account_id: account_id}]
    |> Oban.Job.query()
    |> order_by([j], asc: j.inserted_at)
    |> Repo.all()
    |> Enum.map(&format_queued_email/1)
  end

  def assert_email_queued(account_id, fun) do
    [email | _] = collect_queued_emails(account_id)
    fun.(email)
  end

  def refute_email_queued(account_id) do
    assert collect_queued_emails(account_id) == []
  end

  defp format_queued_email(job) do
    request = job.args["request"] || %{}

    %{
      subject: request["subject"],
      text_body: request["text_body"],
      html_body: request["html_body"],
      to: format_addresses(request["to"]),
      bcc: format_addresses(request["bcc"])
    }
  end

  defp format_addresses(nil), do: []

  defp format_addresses(addresses) do
    Enum.map(addresses, fn
      %{"name" => name, "address" => address} -> {name, address}
      %{"address" => address} -> {nil, address}
    end)
  end
end

defmodule Portal.Workers.OutboundEmail do
  @moduledoc """
  Oban worker that submits a queued email using the secondary outbound adapter.
  """

  use Oban.Worker, queue: :outbound_emails, max_attempts: 1

  alias Portal.Mailer
  require Logger

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"account_id" => account_id, "request" => request}}) do
    email = request |> deserialize() |> put_acs_client_options()
    result = Mailer.deliver_secondary(email)
    persist_delivery_result(result, account_id, email)
  end

  defp put_acs_client_options(%Swoosh.Email{} = email) do
    req_opts = Portal.Config.fetch_env!(:portal, Portal.Mailer.Secondary)[:req_opts] || []

    if req_opts == [] do
      email
    else
      Swoosh.Email.put_private(email, :client_options, req_opts)
    end
  end

  defp persist_delivery_result({:ok, response}, account_id, email) do
    with message_id when is_binary(message_id) <- response_message_id(response),
         {:ok, _} <-
           Mailer.insert_tracked_delivery(
             account_id,
             message_id,
             email.subject,
             email_addresses(email)
           ) do
      :ok
    else
      nil ->
        Logger.error("ACS queued email response did not include a message id",
          account_id: account_id,
          response: inspect(response)
        )

        {:discard, :missing_message_id}

      {:error, reason} ->
        Logger.error("Failed to persist tracked outbound email; email was already sent",
          account_id: account_id,
          message_id: response_message_id(response),
          reason: inspect(reason)
        )

        {:discard, {:track_delivery, reason}}
    end
  end

  defp persist_delivery_result({:error, reason}, account_id, _email) do
    Logger.error("Queued email delivery failed",
      account_id: account_id,
      reason: inspect(reason)
    )

    {:discard, reason}
  end

  defp email_addresses(%Swoosh.Email{} = email) do
    (List.wrap(email.to) ++ List.wrap(email.cc) ++ List.wrap(email.bcc))
    |> Enum.map(fn
      {_, addr} -> addr
      addr -> addr
    end)
  end

  defp deserialize(
         %{
           "from" => from,
           "subject" => subject,
           "html_body" => html_body,
           "text_body" => text_body
         } = request
       ) do
    Swoosh.Email.new()
    |> maybe_put_recipients(:to, request["to"] || [])
    |> maybe_put_recipients(:cc, request["cc"] || [])
    |> maybe_put_recipients(:bcc, request["bcc"] || [])
    |> Swoosh.Email.from({from["name"], from["address"]})
    |> Swoosh.Email.subject(subject)
    |> Swoosh.Email.html_body(html_body)
    |> Swoosh.Email.text_body(text_body)
  end

  defp maybe_put_recipients(email, _field, []), do: email

  defp maybe_put_recipients(email, field, recipients) do
    mapped =
      Enum.map(recipients, fn %{"name" => name, "address" => address} -> {name, address} end)

    case field do
      :to -> Swoosh.Email.to(email, mapped)
      :cc -> Swoosh.Email.cc(email, mapped)
      :bcc -> Swoosh.Email.bcc(email, mapped)
    end
  end

  defp response_message_id(response) when is_map(response), do: response[:id] || response["id"]
  defp response_message_id(_response), do: nil
end

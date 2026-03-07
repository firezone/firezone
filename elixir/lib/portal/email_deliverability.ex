defmodule Portal.EmailDeliverability do
  @moduledoc """
  Recipient-level delivery tracking and suppression handling.
  """

  alias Portal.EmailSuppression
  alias __MODULE__.Database

  @type update_opts :: [
          occurred_at: DateTime.t(),
          failure_code: String.t() | nil,
          failure_message: String.t() | nil
        ]

  def mark_delivered(message_id, recipient_email, opts \\ []) do
    update_recipient(message_id, recipient_email, :delivered, opts)
  end

  def mark_failed(message_id, recipient_email, opts \\ []) do
    update_recipient(message_id, recipient_email, :failed, opts)
  end

  def mark_suppressed(message_id, recipient_email, opts \\ []) do
    update_recipient(message_id, recipient_email, :suppressed, opts)
  end

  def mark_bounced(message_id, recipient_email, opts \\ []) do
    normalized_email = EmailSuppression.normalize_email(recipient_email)

    Database.bounce_recipient(message_id, normalized_email, opts)
  end

  defp update_recipient(message_id, recipient_email, status, opts) do
    Database.update_recipient(message_id, recipient_email, status, opts)
  end

  defmodule Database do
    import Ecto.Query

    alias Portal.{OutboundEmail, OutboundEmailRecipient, EmailSuppression, Safe}

    def bounce_recipient(message_id, recipient_email, opts) do
      Safe.transact(fn ->
        case update_recipient(message_id, recipient_email, :bounced, opts) do
          {:ok, count} ->
            insert_suppression(
              recipient_email,
              Keyword.get(opts, :occurred_at, DateTime.utc_now())
            )

            {:ok, count}

          {:error, reason} ->
            {:error, reason}
        end
      end)
    end

    def update_recipient(message_id, recipient_email, status, opts) do
      occurred_at = Keyword.get(opts, :occurred_at, DateTime.utc_now())
      normalized_email = EmailSuppression.normalize_email(recipient_email)

      attrs = [
        status: status,
        last_event_at: occurred_at,
        failure_code: Keyword.get(opts, :failure_code),
        failure_message: Keyword.get(opts, :failure_message),
        updated_at: occurred_at
      ]

      {count, _result} =
        recipient_query(message_id, normalized_email)
        |> Safe.unscoped()
        |> Safe.update_all(set: attrs)

      case count do
        0 -> {:error, :not_found}
        _ -> {:ok, count}
      end
    end

    defp recipient_query(message_id, recipient_email) do
      from(r in OutboundEmailRecipient,
        join: q in OutboundEmail,
        on: q.id == r.outbound_email_id,
        where: q.message_id == ^message_id,
        where: r.email == ^recipient_email
      )
    end

    defp insert_suppression(email, occurred_at) do
      Safe.unscoped()
      |> Safe.insert_all(EmailSuppression, [%{email: email, inserted_at: occurred_at}],
        on_conflict: :nothing,
        conflict_target: [:email]
      )
    end
  end
end

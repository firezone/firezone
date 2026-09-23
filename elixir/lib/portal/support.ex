defmodule Portal.Support do
  @moduledoc "Support feedback submitted from the portal."

  alias __MODULE__.Database

  import Swoosh.Email

  def changeset(params) do
    {%{}, %{message: :string}}
    |> Ecto.Changeset.cast(params, [:message])
    |> Ecto.Changeset.validate_required([:message])
    |> Ecto.Changeset.validate_length(:message, max: 1000)
  end

  def submit(subject, params, url, screenshot \\ nil) do
    with {:ok, %{message: message}} <- Ecto.Changeset.apply_action(changeset(params), :insert),
         :ok <- validate_url(url),
         {:ok, attachment} <- attachment(screenshot),
         {:ok, :reserved} <- Database.reserve(subject.account.id) do
      email =
        Portal.Mailer.default_email()
        |> to("support@firezone.dev")
        |> subject("In-portal feedback submission")
        |> text_body("""
        Account ID: #{subject.account.id}
        Actor ID: #{subject.actor.id}
        URL: #{url}

        #{message}
        """)

      email = if attachment, do: attachment(email, attachment), else: email
      Portal.Mailer.deliver(email)
    end
  end

  defp validate_url(url) when is_binary(url) and byte_size(url) <= 16_384 do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host} when scheme in ["http", "https"] and is_binary(host) -> :ok
      _ -> {:error, :invalid_url}
    end
  end

  defp validate_url(_), do: {:error, :invalid_url}

  defp attachment(nil), do: {:ok, nil}

  defp attachment(data) when is_binary(data) and byte_size(data) <= 2 * 1024 * 1024 do
    case image_type(data) do
      {extension, type} ->
        {:ok,
         Swoosh.Attachment.new({:data, data},
           filename: "screenshot.#{extension}",
           content_type: type
         )}

      nil ->
        {:error, :invalid_image}
    end
  end

  defp attachment(_), do: {:error, :invalid_image}

  defp image_type(<<137, "PNG\r\n", 26, "\n", _::binary>>), do: {"png", "image/png"}
  defp image_type(<<255, 216, 255, _::binary>>), do: {"jpg", "image/jpeg"}

  defp image_type(<<"GIF", version::binary-size(3), _::binary>>) when version in ["87a", "89a"],
    do: {"gif", "image/gif"}

  defp image_type(<<"RIFF", _::binary-size(4), "WEBP", _::binary>>), do: {"webp", "image/webp"}
  defp image_type(_), do: nil

  defmodule Database do
    @moduledoc false
    alias Portal.Safe

    # Serialize reservations across nodes. Store only timestamps, never feedback or images.
    def reserve(account_id) do
      account_id = Ecto.UUID.dump!(account_id)

      Safe.unscoped()
      |> Safe.transaction(fn ->
        query!("SELECT id FROM accounts WHERE id = $1 FOR UPDATE", [account_id])

        query!(
          "DELETE FROM support_requests WHERE account_id = $1 AND inserted_at <= now() - interval '24 hours'",
          [account_id]
        )

        %{rows: [[count]]} =
          query!("SELECT count(*) FROM support_requests WHERE account_id = $1", [account_id])

        if count >= 10 do
          {:error, :rate_limited}
        else
          query!(
            "INSERT INTO support_requests (account_id, inserted_at) VALUES ($1, clock_timestamp())",
            [account_id]
          )

          {:ok, :reserved}
        end
      end)
    end

    defp query!(sql, params) do
      {:ok, result} = Safe.unscoped() |> Safe.query(sql, params)
      result
    end
  end
end

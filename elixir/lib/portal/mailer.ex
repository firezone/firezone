defmodule Portal.Mailer do
  alias Swoosh.Mailer
  alias Swoosh.Email
  alias Portal.EmailSuppression
  alias Portal.Mailer.RateLimiter
  alias __MODULE__.Database
  require Logger

  @recipient_fields [{"to", :to}, {"cc", :cc}, {"bcc", :bcc}]

  def deliver_with_rate_limit(email, config \\ []) do
    {key, config} =
      Keyword.pop(config, :rate_limit_key, {email.to, email.cc, email.bcc, email.subject})

    {rate_limit, config} = Keyword.pop(config, :rate_limit, 10)
    {rate_limit_interval, config} = Keyword.pop(config, :rate_limit_interval, :timer.minutes(2))

    RateLimiter.rate_limit(key, rate_limit, rate_limit_interval, fn ->
      deliver(email, config)
    end)
    |> case do
      {:ok, result} -> result
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Delivers an email via configured Swoosh adapter.

  If adapter is not configured or is set to nil, the delivery will be ignored and
  function will return `{:ok, %{}}`.

  Notice: this code is copied from `Swoosh.Mailer.deliver/2` and modified to
  not send emails if adapter is not configured. This is needed to avoid
  custom adapter implementation that does nothing.
  """
  def deliver(email, config \\ []) do
    opts = Mailer.parse_config(:portal, __MODULE__, [], config)
    metadata = %{email: email, config: config, mailer: __MODULE__}

    deliver_with_mailer_config(email, opts, metadata)
  end

  def deliver_secondary(email, config \\ []) do
    opts =
      Portal.Config.fetch_env!(:portal, Portal.Mailer.Secondary)
      |> Keyword.merge(config)

    metadata = %{email: email, config: config, mailer: Portal.Mailer.Secondary}

    deliver_with_mailer_config(email, opts, metadata)
  end

  defp deliver_with_mailer_config(email, opts, metadata) do
    if opts[:adapter] do
      deliver_with_telemetry(email, opts, metadata)
    else
      Logger.info("Emails are not configured", email_subject: inspect(email.subject))
      {:ok, %{}}
    end
  end

  defp deliver_with_telemetry(email, opts, metadata) do
    :telemetry.span([:swoosh, :deliver], metadata, fn ->
      case Mailer.deliver(email, opts) do
        {:ok, result} -> {{:ok, result}, Map.put(metadata, :result, result)}
        {:error, error} -> {{:error, error}, Map.put(metadata, :error, error)}
      end
    end)
  end

  # sobelow_skip ["DOS.StringToAtom"]
  defp render_template(view, template, format, assigns) do
    heex = apply(view, String.to_atom("#{template}_#{format}"), [assigns])
    assigns = Keyword.merge(assigns, inner_content: heex)
    Phoenix.Template.render_to_string(view, "#{template}_#{format}", "html", assigns)
  end

  def render_body(%Swoosh.Email{} = email, view, template, assigns) do
    assigns = assigns ++ [email: email]

    email
    |> Email.html_body(render_template(view, template, "html", assigns))
    |> Email.text_body(render_template(view, template, "text", assigns))
  end

  def render_text_body(%Swoosh.Email{} = email, view, template, assigns) do
    assigns = assigns ++ [email: email]

    email
    |> Email.text_body(render_template(view, template, "text", assigns))
  end

  def active? do
    mailer_config = Portal.Config.fetch_env!(:portal, Portal.Mailer)
    mailer_config[:from_email] && mailer_config[:adapter]
  end

  def default_email do
    # Fail hard if email not configured
    from_email =
      Portal.Config.fetch_env!(:portal, Portal.Mailer)
      |> Keyword.fetch!(:from_email)

    Email.new()
    |> Email.from({"Firezone Notifications", from_email})
  end

  def with_account(%Email{} = email, account_id) do
    Email.put_private(email, :account_id, account_id)
  end

  def bcc_recipients(%Email{} = email, recipients) when is_list(recipients) do
    Enum.reduce(recipients, email, fn recipient, acc ->
      Email.bcc(acc, recipient)
    end)
  end

  @doc """
  Enqueues an email for delivery via the outbound email worker.

  priority: :now — delivers inline, tracks result in the DB row, and returns
  the same result as `deliver/2`.
  priority: :later — inserts only; worker delivers asynchronously.
  """
  def enqueue(%Email{} = email, :now) do
    account_id = email.private[:account_id]
    request = serialize(email)

    with {:ok, entry} <- Database.insert_queued(account_id, :now, request, DateTime.utc_now()),
         deliver_result <- deliver(email),
         {status, response} <- classify_inline_delivery_result(deliver_result),
         {:ok, _updated_entry} <- Database.update_status(entry, status, response) do
      deliver_result
    end
  end

  def enqueue(%Email{} = email, :later) do
    account_id = email.private[:account_id]
    request = serialize(email)

    case drop_suppressed_recipients(request) do
      {:ok, filtered_request} ->
        Database.insert_queued(account_id, :later, filtered_request, nil)

      :fully_suppressed ->
        Logger.info("Skipping queued email because all recipients are suppressed",
          account_id: account_id,
          subject: inspect(email.subject)
        )

        {:ok, :suppressed}
    end
  end

  defp serialize(%Email{} = email) do
    %{
      "to" => serialize_addresses(email.to),
      "cc" => serialize_addresses(email.cc),
      "bcc" => serialize_addresses(email.bcc),
      "from" =>
        case email.from do
          {name, addr} -> %{"name" => name, "address" => addr}
          addr -> %{"name" => "", "address" => addr}
        end,
      "subject" => email.subject,
      "html_body" => email.html_body,
      "text_body" => email.text_body
    }
  end

  defp serialize_addresses(addresses) do
    addresses
    |> List.wrap()
    |> Enum.map(fn
      {name, addr} -> %{"name" => name, "address" => addr}
      addr when is_binary(addr) -> %{"name" => "", "address" => addr}
    end)
  end

  defp drop_suppressed_recipients(request) do
    suppressed_emails =
      request
      |> recipient_addresses()
      |> Database.suppressed_recipient_addresses()

    filtered_request =
      Enum.reduce(@recipient_fields, request, fn {field, _kind}, acc ->
        recipients = Map.get(acc, field, [])

        Map.put(
          acc,
          field,
          Enum.reject(recipients, fn %{"address" => address} ->
            EmailSuppression.normalize_email(address) in suppressed_emails
          end)
        )
      end)

    case recipient_addresses(filtered_request) do
      [] -> :fully_suppressed
      _ -> {:ok, filtered_request}
    end
  end

  defp classify_inline_delivery_result({:ok, resp}), do: {:running, resp}

  defp classify_inline_delivery_result({:error, {code, body}})
       when is_integer(code) and code in 400..499 do
    {:failed, %{"status" => code, "body" => inspect(body)}}
  end

  defp classify_inline_delivery_result({:error, reason}) do
    {:errored, %{"reason" => inspect(reason)}}
  end

  defp recipient_addresses(request) do
    Enum.flat_map(@recipient_fields, fn {field, _kind} ->
      Enum.map(Map.get(request, field, []), fn %{"address" => address} -> address end)
    end)
  end

  defmodule Database do
    import Ecto.Query
    alias Portal.Safe
    alias Portal.{OutboundEmailRecipient, EmailSuppression}

    def insert_queued(account_id, priority, request, last_attempted_at) do
      Safe.transact(fn ->
        with {:ok, entry} <- insert_entry(account_id, priority, request, last_attempted_at),
             {:ok, _recipient_count} <- insert_recipients(entry, request) do
          {:ok, entry}
        else
          {:error, reason} -> {:error, reason}
        end
      end)
      |> case do
        {:ok, entry} -> {:ok, entry}
        {:error, reason} -> {:error, reason}
      end
    end

    def update_status(%Portal.OutboundEmail{} = entry, status, response) do
      entry
      |> Ecto.Changeset.change(status: status, response: response)
      |> Safe.unscoped()
      |> Safe.update()
    end

    def suppressed_recipient_addresses(recipients) do
      addresses =
        recipients
        |> Enum.map(&EmailSuppression.normalize_email/1)

      if addresses == [] do
        []
      else
        from(s in EmailSuppression, where: s.email in ^addresses, select: s.email)
        |> Safe.unscoped(:replica)
        |> Safe.all()
      end
    end

    defp insert_entry(account_id, priority, request, last_attempted_at) do
      %Portal.OutboundEmail{
        account_id: account_id,
        priority: priority,
        request: request,
        last_attempted_at: last_attempted_at
      }
      |> Safe.unscoped()
      |> Safe.insert()
    end

    defp insert_recipients(%Portal.OutboundEmail{} = entry, request) do
      attrs = recipient_attrs(entry, request)

      if attrs == [] do
        {:ok, 0}
      else
        Safe.unscoped()
        |> Safe.insert_all(OutboundEmailRecipient, attrs)

        {:ok, length(attrs)}
      end
    end

    defp recipient_attrs(%Portal.OutboundEmail{} = entry, request) do
      now = DateTime.utc_now()

      [{"to", :to}, {"cc", :cc}, {"bcc", :bcc}]
      |> Enum.flat_map(fn {field, kind} ->
        request
        |> Map.get(field, [])
        |> Enum.map(fn %{"address" => address} ->
          %{
            id: Ecto.UUID.generate(),
            account_id: entry.account_id,
            outbound_email_id: entry.id,
            kind: kind,
            email: EmailSuppression.normalize_email(address),
            status: :pending,
            inserted_at: now,
            updated_at: now
          }
        end)
      end)
      |> Enum.uniq_by(fn %{kind: kind, email: email} -> {kind, email} end)
    end
  end
end

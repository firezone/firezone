defmodule Portal.Mailer do
  use Supervisor
  alias Swoosh.Mailer
  alias Swoosh.Email
  alias Portal.Mailer.RateLimiter
  require Logger

  def start_link(arg) do
    Supervisor.start_link(__MODULE__, arg, name: __MODULE__)
  end

  def init(_arg) do
    children = [
      {Finch, name: Swoosh.Finch}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  def deliver_with_rate_limit(email, config \\ []) do
    {key, config} = Keyword.pop(config, :rate_limit_key, {email.to, email.subject})
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
    opts = Mailer.parse_config(:domain, __MODULE__, [], config)
    metadata = %{email: email, config: config, mailer: __MODULE__}

    if opts[:adapter] do
      :telemetry.span([:swoosh, :deliver], metadata, fn ->
        case Mailer.deliver(email, opts) do
          {:ok, result} -> {{:ok, result}, Map.put(metadata, :result, result)}
          {:error, error} -> {{:error, error}, Map.put(metadata, :error, error)}
        end
      end)
    else
      Logger.info("Emails are not configured", email_subject: inspect(email.subject))
      {:ok, %{}}
    end
  end

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
    mailer_config = Portal.Config.fetch_env!(:domain, Portal.Mailer)
    mailer_config[:from_email] && mailer_config[:adapter]
  end

  def default_email do
    # Fail hard if email not configured
    from_email =
      Portal.Config.fetch_env!(:domain, Portal.Mailer)
      |> Keyword.fetch!(:from_email)

    Email.new()
    |> Email.from({"Firezone Notifications", from_email})
  end

  def url(path, params \\ %{}) do
    Portal.Config.fetch_env!(:domain, :web_external_url)
    |> URI.parse()
    |> URI.append_path(path)
    |> maybe_append_query(params)
    |> URI.to_string()
  end

  defp maybe_append_query(uri, params) do
    if Enum.empty?(params) do
      uri
    else
      URI.append_query(uri, URI.encode_query(params))
    end
  end
end

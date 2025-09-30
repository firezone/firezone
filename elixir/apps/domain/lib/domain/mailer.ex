defmodule Domain.Mailer do
  use Supervisor
  alias Swoosh.Mailer
  alias Swoosh.Email
  alias Domain.Mailer.RateLimiter
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
    mailer_config = Domain.Config.fetch_env!(:domain, Domain.Mailer)
    mailer_config[:from_email] && mailer_config[:adapter]
  end

  def default_email do
    # Fail hard if email not configured
    from_email =
      Domain.Config.fetch_env!(:domain, Domain.Mailer)
      |> Keyword.fetch!(:from_email)

    Email.new()
    |> Email.from({"Firezone Notifications", from_email})
  end

  def url(path, params \\ %{}) do
    Domain.Config.fetch_env!(:domain, :web_external_url)
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

  @doc """
  Returns dark mode CSS styles for email templates.

  These styles are applied when the user's email client has dark mode enabled.
  """
  def dark_mode_styles do
    """
    @media (prefers-color-scheme: dark) {
      body {
        background-color: #1a1a1a !important;
      }
      .email-container {
        background-color: #1a1a1a !important;
      }
      .content-box {
        background-color: #2d2d2d !important;
        color: #e5e5e5 !important;
      }
      .content-box h1,
      .content-box h2 {
        color: #ffffff !important;
      }
      .content-box p,
      .content-box td {
        color: #e5e5e5 !important;
      }
      .content-box th {
        color: #d4d4d4 !important;
      }
      .content-box table tr {
        background-color: #2d2d2d !important;
      }
      .content-box code {
        background-color: #1a1a1a !important;
        border-color: #525252 !important;
        color: #e5e5e5 !important;
      }
      .content-box pre {
        background-color: #1a1a1a !important;
        color: #e5e5e5 !important;
      }
      .separator {
        background-color: #525252 !important;
      }
      .footer-text {
        color: #a3a3a3 !important;
      }
      .logo-light {
        display: none !important;
        max-height: 0 !important;
        overflow: hidden !important;
      }
      .logo-dark {
        display: inline-block !important;
      }
    }
    @media (prefers-color-scheme: light) {
      .logo-dark {
        display: none !important;
        max-height: 0 !important;
        overflow: hidden !important;
      }
    }
    """
  end
end

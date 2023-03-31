defmodule FzHttp.ConnectivityChecks do
  @moduledoc """
  The ConnectivityChecks context.
  """
  use Supervisor
  alias FzHttp.Repo
  alias FzHttp.Auth
  alias FzHttp.ConnectivityChecks.{Poller, ConnectivityCheck, Authorizer}

  @http_client_process_name __MODULE__.Finch

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def init(_opts) do
    config = FzHttp.Config.fetch_env!(:fz_http, FzHttp.ConnectivityChecks)
    transport_opts = Keyword.fetch!(config, :http_client_options)

    children =
      if Keyword.fetch!(config, :enabled) == true do
        application_version = Application.spec(:fz_http, :vsn) |> to_string()
        connectivity_checks_url = Keyword.fetch!(config, :url)

        request = Finch.build(:get, connectivity_checks_url <> application_version)

        [{Poller, request}]
      else
        []
      end

    children =
      children ++
        [
          {Finch,
           name: @http_client_process_name,
           pools: %{default: [conn_opts: [transport_opts: transport_opts]]}}
        ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  def list_connectivity_checks(%Auth.Subject{} = subject, opts \\ []) do
    with :ok <-
           Auth.ensure_has_permissions(subject, Authorizer.view_connectivity_checks_permission()) do
      {limit, _opts} = Keyword.pop(opts, :limit, 100)

      ConnectivityCheck.Query.all()
      |> ConnectivityCheck.Query.order_by_inserted_at()
      |> ConnectivityCheck.Query.with_limit(limit)
      |> Authorizer.for_subject(subject)
      |> Repo.all()
    end
  end

  def check_connectivity(%Finch.Request{} = request) do
    with {:ok, %Finch.Response{headers: headers, body: response, status: status}} <-
           Finch.request(request, @http_client_process_name) do
      ConnectivityCheck.Changeset.create_changeset(%{
        response_body: response,
        response_code: status,
        response_headers: Map.new(headers),
        url: "#{request.scheme}://#{request.host}:#{request.port}#{request.path}"
      })
      |> Repo.insert()
    end
  end
end

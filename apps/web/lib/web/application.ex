defmodule Web.Application do
  use Application

  def start(_type, _args) do
    Supervisor.start_link(children(), strategy: :one_for_one, name: __MODULE__.Supervisor)
  end

  def config_change(changed, _new, removed) do
    Web.Endpoint.config_change(changed, removed)
    :ok
  end

  defp children do
    [
      Web.Presence,
      Web.Endpoint
    ]
  end
end

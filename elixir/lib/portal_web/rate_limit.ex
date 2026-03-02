defmodule PortalWeb.RateLimit do
  @moduledoc """
  Distributed, eventually consistent rate limiter for `PortalWeb` HTTP requests.
  """

  @default_cost 10

  def default_cost do
    @default_cost
  end

  def hit(key, refill_rate, capacity, cost \\ @default_cost) do
    :ok = broadcast({:hit, key, refill_rate, capacity, cost, Node.self()})
    PortalWeb.RateLimit.Local.hit(key, refill_rate, capacity, cost)
  end

  defmodule Local do
    @moduledoc false
    use Hammer, backend: :ets, algorithm: :token_bucket
  end

  defmodule Listener do
    @moduledoc false
    use GenServer

    @doc false
    def start_link(opts) do
      topic = Keyword.fetch!(opts, :topic)
      GenServer.start_link(__MODULE__, topic)
    end

    @impl true
    def init(topic) do
      :ok = Portal.PubSub.subscribe(topic)
      {:ok, []}
    end

    @impl true
    def handle_info({:hit, key, refill_rate, capacity, cost, node}, state) do
      if node != Node.self() do
        {_allow_deny, _int} = Local.hit(key, refill_rate, capacity, cost)
      end

      {:noreply, state}
    end
  end

  @topic "__webratelimit"

  defp broadcast(message) do
    Portal.PubSub.broadcast(@topic, message)
  end

  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      type: :supervisor
    }
  end

  def start_link(opts) do
    children = [{Local, opts}, {Listener, topic: @topic}]
    Supervisor.start_link(children, strategy: :one_for_one)
  end
end

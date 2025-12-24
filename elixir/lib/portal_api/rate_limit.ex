defmodule API.RateLimit do
  @moduledoc """
  Distributed, eventually consistent rate limiter using `Domain.PubSub` and `Hammer`.

  This module provides a rate-limiting mechanism for requests using a distributed,
  eventually consistent approach. It combines local in-memory counting with a
  broadcasting mechanism to keep counters in sync across nodes in a cluster.
  """

  @default_cost 10

  def default_cost do
    @default_cost
  end

  def hit(key, refill_rate, capacity, cost \\ @default_cost) do
    :ok = broadcast({:hit, key, refill_rate, capacity, cost, Node.self()})
    API.RateLimit.Local.hit(key, refill_rate, capacity, cost)
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
      :ok = Domain.PubSub.subscribe(topic)
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

  @topic "__ratelimit"

  defp broadcast(message) do
    Domain.PubSub.broadcast(@topic, message)
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

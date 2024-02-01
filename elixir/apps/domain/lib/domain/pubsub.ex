defmodule Domain.PubSub do
  @moduledoc """
  A wrapper around Phoenix.PubSub that allows us not to spread the knowledge of the process name
  across applications.
  """
  use Supervisor

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts)
  end

  def init(_opts) do
    children = [
      {Phoenix.PubSub, name: __MODULE__}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  @doc """
  See `Phoenix.PubSub.broadcast/3`.

  Keep in mind that Phoenix.Presence is also using the same PubSub process,
  so you can broadcast to Phoenix.Presence topics as well. This feature is
  used in some of domain contexts.
  """
  def broadcast(topic, payload) do
    Phoenix.PubSub.broadcast(__MODULE__, topic, payload)
  end

  @doc """
  See `Phoenix.PubSub.subscribe/2`.
  """
  def subscribe(topic) do
    Phoenix.PubSub.subscribe(__MODULE__, topic)
  end

  @doc """
  See `Phoenix.PubSub.unsubscribe/2`.
  """
  def unsubscribe(topic) do
    Phoenix.PubSub.unsubscribe(__MODULE__, topic)
  end
end

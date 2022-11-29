defmodule FzHttp.Configurations.Cache do
  @moduledoc """
  Manipulate cached configurations.
  """

  use GenServer, restart: :transient

  alias FzHttp.Configurations
  import Actual.Application

  @name :conf

  def get(key) do
    Cachex.get(@name, key)
  end

  def get!(key) do
    Cachex.get!(@name, key)
  end

  def put(key, value) do
    Cachex.put(@name, key, value)
  end

  def put!(key, value) do
    Cachex.put!(@name, key, value)
  end

  def start_link(_) do
    GenServer.start_link(__MODULE__, [])
  end

  @no_fallback [:logo]

  @impl true
  def init(_) do
    configurations =
      Configurations.get_configuration!()
      |> Map.from_struct()
      |> Map.delete(:id)

    for {k, v} <- configurations do
      # XXX: Remove fallbacks before 1.0?
      v =
        with nil <- v, true <- k not in @no_fallback do
          app().fetch_env!(:fz_http, k)
        else
          _ -> v
        end

      {:ok, _} = put(k, v)
    end

    :ignore
  end
end

defmodule FzHttp.Conf.Cache do
  @moduledoc """
  Manipulate cached configurations.
  """

  use GenServer, restart: :transient

  alias FzHttp.Conf

  def get(key) do
    :persistent_term.get({:fz_http, key}, nil)
  end

  def put(key, value) do
    :persistent_term.put({:fz_http, key}, value)
  end

  def start_link(_) do
    GenServer.start_link(__MODULE__, [])
  end

  @impl true
  def init(_) do
    configurations =
      Conf.get_configuration!()
      |> Map.from_struct()
      |> Map.delete(:id)

    for {k, v} <- configurations do
      # XXX: Remove fallbacks before 1.0?
      v =
        with nil <- v do
          Application.fetch_env!(:fz_http, k)
        end

      :ok = put(k, v)
    end

    :ignore
  end
end

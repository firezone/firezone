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
      put(k, v)
    end

    {:ok, []}
  end
end

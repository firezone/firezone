defmodule Portal.Types.Filter do
  @moduledoc """
  Ecto type implementation for `Portal.Repo.Filter` which uses
  Erlang External Term Format to store them in database.
  """
  alias Portal.Repo.Filter

  @behaviour Ecto.Type

  def type, do: :binary

  def embed_as(_), do: :self

  def equal?(left, right), do: left == right

  def cast(%Filter{} = filter), do: {:ok, filter}

  # sobelow_skip ["Misc.BinToTerm"]
  def cast(binary) when is_binary(binary) do
    filter =
      binary
      |> Base.decode64!(padding: false)
      |> :erlang.binary_to_term([:safe])

    {:ok, filter}
  end

  def cast(_), do: :error

  def dump(%Filter{} = filter) do
    binary =
      filter
      |> :erlang.term_to_binary()
      |> Base.encode64(padding: false)

    {:ok, binary}
  end

  def dump(_), do: :error

  def load(%Filter{} = filter), do: {:ok, filter}
  def load(_), do: :error
end

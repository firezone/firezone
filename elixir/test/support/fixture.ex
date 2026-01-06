defmodule Portal.Fixture do
  alias Portal.Repo

  defmacro __using__(_opts) do
    quote do
      import Portal.Fixture
      alias Portal.Repo
      alias Portal.Fixtures
    end
  end

  def pop_assoc_fixture_id(attrs, key, callback) do
    case Map.fetch(attrs, :"#{key}_id") do
      {:ok, id} when not is_nil(id) ->
        {id, attrs}

      _other ->
        {assoc, attrs} = pop_assoc_fixture(attrs, key, callback)
        {assoc.id, attrs}
    end
  end

  def pop_assoc_fixture(attrs, key, callback) do
    case Map.pop(attrs, key, %{}) do
      {%{__struct__: _struct} = assoc_struct, attrs} ->
        {assoc_struct, attrs}

      {assoc_attrs, attrs} ->
        {apply_assoc_fixture(callback, assoc_attrs), attrs}
    end
  end

  defp apply_assoc_fixture(callback, _attrs) when is_function(callback, 0), do: callback.()
  defp apply_assoc_fixture(callback, attrs) when is_function(callback, 1), do: callback.(attrs)

  def update!(schema, changes) do
    schema
    |> Ecto.Changeset.change(Enum.into(changes, %{}))
    |> Repo.update!()
  end

  def unique_integer do
    System.unique_integer([:positive, :monotonic])
  end

  def unique_ipv4 do
    number = unique_integer()
    <<a::size(8), b::size(8), c::size(8), d::size(8)>> = <<number::32>>
    {a, b, c, d}
  end

  def unique_ipv6 do
    number = unique_integer()

    <<a::size(16), b::size(16), c::size(16), d::size(16), e::size(16), f::size(16), g::size(16),
      h::size(16)>> = <<number::128>>

    {a, b, c, d, e, f, g, h}
  end

  def unique_public_key do
    :crypto.strong_rand_bytes(32)
    |> Base.encode64()
  end
end

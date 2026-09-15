defmodule Portal.Policies.Postures.ChecksTest do
  use ExUnit.Case, async: true

  alias Portal.Policies.Postures
  alias Portal.Policies.Postures.{Check, Checks}

  test "every check parses, names its providers truthfully and round-trips by name" do
    for check <- Checks.all() do
      assert {:ok, %Postures{expr: %Check{name: name, expr: expr}}} = Postures.cast(%{"check" => Atom.to_string(check.name)})
      assert name == check.name
      assert expr != nil
      assert providers(check.expansion) == Enum.sort(check.providers), "#{check.name} lists the wrong providers"
      assert check.platforms != []
      assert Postures.to_map(%Postures{expr: %Check{name: name, expr: expr}}) == %{"check" => Atom.to_string(check.name)}
    end
  end

  test "names/0 and fetch/1 agree" do
    for name <- Checks.names() do
      assert {:ok, %{name: ^name}} = Checks.fetch(name)
      assert {:ok, %{name: ^name}} = Checks.fetch(Atom.to_string(name))
    end

    assert Checks.fetch(:bogus) == :error
    assert Checks.fetch("bogus") == :error
  end

  defp providers(%{"field" => field}), do: [field |> String.split(".") |> hd() |> String.to_existing_atom()]
  defp providers(%{"not" => node}), do: providers(node)
  defp providers(%{"and" => nodes}), do: nodes |> Enum.flat_map(&providers/1) |> Enum.uniq() |> Enum.sort()
  defp providers(%{"or" => nodes}), do: nodes |> Enum.flat_map(&providers/1) |> Enum.uniq() |> Enum.sort()
end

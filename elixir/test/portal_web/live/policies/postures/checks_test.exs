defmodule PortalWeb.Policies.Postures.ChecksTest do
  use ExUnit.Case, async: true

  alias Portal.Policies.Postures
  alias PortalWeb.Policies.Postures.Checks

  test "every check expands to a valid tree and names its providers truthfully" do
    for check <- Checks.all() do
      assert {:ok, postures} = Postures.cast(check.expansion), "#{check.name} does not parse"
      assert Postures.to_map(postures) == check.expansion
      assert providers(check.expansion) == Enum.sort(check.providers), "#{check.name} lists the wrong providers"
      assert check.platforms != []
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

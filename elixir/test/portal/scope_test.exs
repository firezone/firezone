defmodule Portal.ScopeTest do
  use ExUnit.Case, async: true

  alias Portal.Scope

  describe "all/0" do
    test "issues exactly the levels each entity declares" do
      expected =
        Enum.flat_map(Scope.levels_by_entity(), fn {entity, levels} ->
          Enum.map(levels, &"#{entity}:#{&1}")
        end)

      assert Scope.all() == expected
    end

    test "offers no level an endpoint would never check" do
      # A gateway token can be minted or revoked, but never read back.
      assert Scope.levels(:account) == [:read]
      assert Scope.levels(:gateway_tokens) == [:write]
    end

    test "grants minting a credential apart from reading what it belongs to" do
      assert :client_tokens in Scope.entities()
      assert :gateway_tokens in Scope.entities()
    end
  end

  describe "expand/1" do
    test "write implies read" do
      assert Scope.expand(["policies:write"]) == ["policies:read", "policies:write"]
    end

    test "read does not imply write" do
      assert Scope.expand(["policies:read"]) == ["policies:read"]
    end

    test "drops scopes this server does not issue" do
      assert Scope.expand(["nonsense", "policies:read", "policies:admin"]) == ["policies:read"]
    end

    test "does not invent a read level for an entity that has none" do
      assert Scope.expand(["gateway_tokens:write"]) == ["gateway_tokens:write"]
    end
  end

  describe "satisfies?/2" do
    test "nil is a credential type that carries no scopes, and is unrestricted" do
      assert Scope.satisfies?(nil, "policies:write")
      assert Scope.satisfies?(nil, "logs:read")
    end

    test "an empty list grants nothing" do
      refute Scope.satisfies?([], "policies:read")
    end

    test "write satisfies a read check" do
      assert Scope.satisfies?(["policies:write"], "policies:read")
    end

    test "read does not satisfy a write check" do
      refute Scope.satisfies?(["policies:read"], "policies:write")
    end

    test "a scope on one entity says nothing about another" do
      refute Scope.satisfies?(["policies:write"], "resources:read")
    end
  end

  describe "required/2" do
    test "get requires read" do
      assert Scope.required(:policies, :get) == "policies:read"
    end

    test "get requires write when the entity has no read level" do
      assert Scope.required(:gateway_tokens, :get) == "gateway_tokens:write"
    end

    test "anything that is not a read requires write" do
      for method <- [:post, :put, :patch, :delete, :write] do
        assert Scope.required(:policies, method) == "policies:write"
      end
    end
  end

  describe "parse/1" do
    test "expands what it parses" do
      assert {:ok, scopes} = Scope.parse("policies:write")
      assert scopes == ["policies:read", "policies:write"]
    end

    test "an absent or empty parameter is an error rather than a default" do
      assert Scope.parse(nil) == {:error, :missing}
      assert Scope.parse("") == {:error, :missing}
      assert Scope.parse("   ") == {:error, :missing}
    end

    test "names the scopes it does not recognise" do
      assert {:error, {:unknown, unknown}} = Scope.parse("policies:read nope:read")
      assert unknown == ["nope:read"]
    end
  end

  describe "validate/2" do
    defp changeset(scopes) do
      {%{}, %{scopes: {:array, :string}}}
      |> Ecto.Changeset.cast(%{scopes: scopes}, [:scopes])
      |> Scope.validate(:scopes)
    end

    test "accepts a known list" do
      assert changeset(["policies:read"]).valid?
    end

    test "rejects an empty list, which would grant nothing" do
      refute changeset([]).valid?
    end

    test "rejects unknown scopes" do
      refute changeset(["policies:read", "made:up"]).valid?
    end

    test "rejects an unknown level for an entity that does not have it" do
      refute changeset(["account:write"]).valid?
    end
  end
end

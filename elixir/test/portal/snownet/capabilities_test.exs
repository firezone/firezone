defmodule Portal.Snownet.CapabilitiesTest do
  use ExUnit.Case, async: true

  alias Portal.Snownet.Capabilities

  describe "intersect/2" do
    test "ANDs known fields" do
      assert Capabilities.intersect(%{"iceless" => true}, %{"iceless" => true}) == %{
               "iceless" => true
             }

      assert Capabilities.intersect(%{"iceless" => true}, %{"iceless" => false}) == %{
               "iceless" => false
             }

      assert Capabilities.intersect(%{"iceless" => false}, %{"iceless" => true}) == %{
               "iceless" => false
             }

      assert Capabilities.intersect(%{"iceless" => false}, %{"iceless" => false}) == %{
               "iceless" => false
             }
    end

    test "missing keys default to false" do
      # If neither side reports `iceless`, the negotiated value is false.
      assert Capabilities.intersect(%{}, %{}) == %{"iceless" => false}

      # If one side reports true but the other doesn't include the key, it's false.
      assert Capabilities.intersect(%{"iceless" => true}, %{}) == %{"iceless" => false}
      assert Capabilities.intersect(%{}, %{"iceless" => true}) == %{"iceless" => false}
    end

    test "ignores unknown fields" do
      # Unknown caps a peer reports — e.g., an older portal hasn't been told
      # about a newer flag — get dropped from the result. The result only
      # contains the fields the portal currently knows about.
      a = %{"iceless" => true, "future_flag" => true}
      b = %{"iceless" => true, "future_flag" => true}

      result = Capabilities.intersect(a, b)
      assert result == %{"iceless" => true}
      refute Map.has_key?(result, "future_flag")
    end

    test "always returns every known field even when both sides omit it" do
      # The output schema is fixed: every known capability is present so the
      # downstream Rust serde struct deserializes deterministically.
      result = Capabilities.intersect(%{}, %{})
      assert Map.has_key?(result, "iceless")
    end

    test "non-boolean values are treated as false instead of crashing" do
      # The `set_snownet_capabilities` channel handler accepts arbitrary
      # untrusted payloads. Using `and` directly on a string would raise
      # `ArgumentError: argument error: argument is not a boolean` and
      # crash the channel; we coerce non-`true` values to `false` instead.
      assert Capabilities.intersect(%{"iceless" => "yes"}, %{"iceless" => true}) == %{
               "iceless" => false
             }

      assert Capabilities.intersect(%{"iceless" => 1}, %{"iceless" => true}) == %{
               "iceless" => false
             }

      assert Capabilities.intersect(%{"iceless" => nil}, %{"iceless" => true}) == %{
               "iceless" => false
             }
    end
  end

  describe "normalize/1" do
    test "drops unknown fields" do
      # Untrusted clients can include arbitrary keys; storing them in
      # presence metadata would let a peer bloat memory at will.
      assert Capabilities.normalize(%{"iceless" => true, "future_flag" => true}) == %{
               "iceless" => true
             }
    end

    test "always returns every known field" do
      # Output schema is fixed so downstream consumers (presence diff,
      # Rust serde) see a deterministic shape.
      assert Capabilities.normalize(%{}) == %{"iceless" => false}
    end

    test "coerces non-boolean values to false" do
      assert Capabilities.normalize(%{"iceless" => "yes"}) == %{"iceless" => false}
      assert Capabilities.normalize(%{"iceless" => 1}) == %{"iceless" => false}
      assert Capabilities.normalize(%{"iceless" => nil}) == %{"iceless" => false}
    end
  end
end

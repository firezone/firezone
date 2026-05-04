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
  end
end

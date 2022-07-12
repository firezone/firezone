defmodule FzCommon.FzStringTest do
  use ExUnit.Case, async: true

  alias FzCommon.FzString

  describe "sanitize_filename/1" do
    test "santizes sequential spaces" do
      assert "Factory_Device" == FzString.sanitize_filename("Factory     Device")
    end
  end

  describe "to_boolean/1" do
    test "converts to true" do
      assert true == FzString.to_boolean("True")
    end

    test "converts to false" do
      assert false == FzString.to_boolean("False")
    end

    test "raises exception on unknowns" do
      message = "Unknown boolean: string foobar not one of ['true', 'false']."

      assert_raise RuntimeError, message, fn ->
        FzString.to_boolean("foobar")
      end
    end
  end

  describe "to_cidr_list/1" do
    test "converts single ip" do
      assert ["10.20.30.40"] == FzString.to_cidr_list("[\"10.20.30.40\"]")
    end

    test "empty list" do
      assert [] == FzString.to_cidr_list("[]")
    end

    test "Works with CIDR" do
      assert ["10.20.30.0/24"] == FzString.to_cidr_list("[\"10.20.30.40/24\"]")
    end

    test "converts multiple ip" do
      assert ["10.20.30.40", "1.2.3.4", "5.6.7.0/24", "::/64"] ==
               FzString.to_cidr_list(
                 ~s([\"10.20.30.40\", \"1.2.3.4\", \"5.6.7.8/24\", \"::/64\"])
               )

      assert ["10.20.30.40", "1.2.3.4", "5.6.7.0/24"] ==
               FzString.to_cidr_list(~s([\"10.20.30.40\",\"1.2.3.4\",\"5.6.7.8/24\" ]))
    end
  end
end

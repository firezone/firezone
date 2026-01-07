defmodule Portal.Types.IPPortTest do
  use ExUnit.Case, async: true
  import Portal.Types.IPPort

  describe "cast_address/1" do
    test "uses strict parsing for IP addresses" do
      assert cast_address("1.1.1") == {:error, :einval}
      assert cast_address("1.1.1.1") == {:ok, {1, 1, 1, 1}}
    end
  end

  describe "cast/1" do
    test "only allows port numbers between 1 - 65_535" do
      assert cast("1.1.1.1:0") == {:error, [message: "is invalid"]}

      assert cast("1.1.1.1:1") ==
               {:ok,
                %Portal.Types.IPPort{
                  address_type: :ipv4,
                  address: {1, 1, 1, 1},
                  port: 1
                }}

      assert cast("1.1.1.1:65535") ==
               {:ok,
                %Portal.Types.IPPort{
                  address_type: :ipv4,
                  address: {1, 1, 1, 1},
                  port: 65_535
                }}

      assert cast("1.1.1.1:65536") == {:error, [message: "is invalid"]}
    end
  end

  describe "put_default_port/1" do
    test "sets default port when one does not exist" do
      {:ok, ip_port} = cast("1.1.1.1")

      assert put_default_port(ip_port, 53) == %Portal.Types.IPPort{
               address_type: :ipv4,
               address: {1, 1, 1, 1},
               port: 53
             }
    end

    test "does not set default port when port exists" do
      {:ok, ip_port} = cast("1.1.1.1:853")

      assert put_default_port(ip_port, 53) == %Portal.Types.IPPort{
               address_type: :ipv4,
               address: {1, 1, 1, 1},
               port: 853
             }
    end
  end
end

defmodule Portal.RemoteIp.XForwardedForParserTest do
  use ExUnit.Case, async: true

  alias Portal.RemoteIp.XForwardedForParser

  describe "parse/1" do
    # Azure App Gateway appends source port to IPv4 addresses
    test "strips port from IPv4:port" do
      assert XForwardedForParser.parse("107.197.104.68:53859") == [{107, 197, 104, 68}]
    end

    # Azure App Gateway appends source port to IPv6 addresses without brackets
    test "strips port from IPv6:port" do
      assert XForwardedForParser.parse("2601:5c1:8200:4e5:49f9:23d9:a1c0:bb0b:64828") ==
               [{0x2601, 0x5C1, 0x8200, 0x04E5, 0x49F9, 0x23D9, 0xA1C0, 0xBB0B}]
    end

    test "passes through valid IPv4 unchanged" do
      assert XForwardedForParser.parse("107.197.104.68") == [{107, 197, 104, 68}]
    end

    test "passes through valid IPv6 unchanged" do
      assert XForwardedForParser.parse("2601:5c1:8200:4e5:49f9:23d9:a1c0:bb0b") ==
               [{0x2601, 0x5C1, 0x8200, 0x04E5, 0x49F9, 0x23D9, 0xA1C0, 0xBB0B}]
    end

    test "passes through compressed IPv6 unchanged" do
      assert XForwardedForParser.parse("::1") == [{0, 0, 0, 0, 0, 0, 0, 1}]
    end

    test "handles comma-separated chain with mixed formats" do
      # Typical App Gateway chain: client IP:port, internal proxy
      assert XForwardedForParser.parse("107.197.104.68:53859, 10.115.8.5") ==
               [{107, 197, 104, 68}, {10, 115, 8, 5}]
    end

    test "handles comma-separated chain of valid IPs" do
      assert XForwardedForParser.parse("1.2.3.4, 5.6.7.8") ==
               [{1, 2, 3, 4}, {5, 6, 7, 8}]
    end

    test "filters out truly invalid values" do
      assert XForwardedForParser.parse("not-an-ip") == []
    end

    test "handles whitespace around values" do
      assert XForwardedForParser.parse("  107.197.104.68:53859  ") == [{107, 197, 104, 68}]
    end
  end
end

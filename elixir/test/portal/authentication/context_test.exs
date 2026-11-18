defmodule Portal.Authentication.ContextTest do
  use ExUnit.Case, async: true

  alias Portal.Authentication.Context

  test "build/4 stores an IPv4-mapped IPv6 address as IPv4" do
    context = Context.build({0, 0, 0, 0, 0, 0xFFFF, 0x6BC5, 0x6844}, "testing", [], :client)

    assert context.remote_ip == {107, 197, 104, 68}
  end

  test "build/4 truncates the user agent to 255 code points" do
    user_agent = String.duplicate("é", 300)
    context = Context.build({127, 0, 0, 1}, user_agent, [], :client)

    assert context.user_agent == String.duplicate("é", 255)
  end
end

defmodule PortalWeb.Plugs.PutDynamicRepoTest do
  use ExUnit.Case, async: true

  import Plug.Test

  alias PortalWeb.Plugs.PutDynamicRepo

  describe "init/1" do
    test "passes options through" do
      assert PutDynamicRepo.init([]) == []
      assert PutDynamicRepo.init(foo: :bar) == [foo: :bar]
    end
  end

  describe "call/2" do
    test "returns conn unchanged" do
      conn = conn(:get, "/")
      result = PutDynamicRepo.call(conn, [])

      assert result == conn
      refute result.halted
    end

    test "does not crash on POST requests" do
      conn = conn(:post, "/test", "body")
      result = PutDynamicRepo.call(conn, [])

      assert result == conn
    end
  end
end

defmodule PortalAPI.PaginationTest do
  use ExUnit.Case, async: true
  alias PortalAPI.Pagination

  describe "params_to_list_opts/2" do
    test "returns empty page opts when no params given" do
      assert {:ok, [page: []]} = Pagination.params_to_list_opts(%{})
    end

    test "returns cursor when page_cursor given" do
      assert {:ok, [page: [cursor: "abc"]]} =
               Pagination.params_to_list_opts(%{"page_cursor" => "abc"})
    end

    test "rejects an oversized page_cursor before it reaches the paginator" do
      cursor = String.duplicate("a", Portal.Repo.Paginator.max_encoded_cursor_bytes() + 1)

      assert {:error, :bad_request, reason: "page_cursor must be at most 2048 bytes"} =
               Pagination.params_to_list_opts(%{"page_cursor" => cursor})
    end

    test "returns limit when limit given" do
      assert {:ok, [page: [limit: 25]]} = Pagination.params_to_list_opts(%{"limit" => "25"})
    end

    test "returns cursor and limit when both given" do
      assert {:ok, [page: [cursor: "abc", limit: 25]]} =
               Pagination.params_to_list_opts(%{"limit" => "25", "page_cursor" => "abc"})
    end

    test "returns a bad_request error for a non-integer limit" do
      assert {:error, :bad_request, reason: _} =
               Pagination.params_to_list_opts(%{"limit" => "abc"})
    end

    test "returns a bad_request error for a float limit" do
      assert {:error, :bad_request, reason: _} =
               Pagination.params_to_list_opts(%{"limit" => "10.5"})
    end

    test "returns a bad_request error for a non-integer limit combined with a cursor" do
      assert {:error, :bad_request, reason: _} =
               Pagination.params_to_list_opts(%{"limit" => "abc", "page_cursor" => "abc"})
    end
  end
end

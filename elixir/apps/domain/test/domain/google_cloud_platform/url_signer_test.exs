defmodule Domain.GoogleCloudPlatform.URLSignerTest do
  use ExUnit.Case, async: true
  import Domain.GoogleCloudPlatform.URLSigner

  describe "canonical_headers/1" do
    test "generates valid canonical form of the headers" do
      headers = [
        {"content-type", "text/plain"},
        {"host", "storage.googleapis.com"},
        {"x-goog-meta-reviewer", "jane"},
        {"x-goog-meta-reviewer", "john"}
      ]

      assert canonical_headers = canonical_headers(headers)
      assert is_binary(canonical_headers)

      assert String.split(canonical_headers, "\n") ==
               [
                 "content-type:text/plain",
                 "host:storage.googleapis.com",
                 "x-goog-meta-reviewer:jane,john"
               ]
    end
  end

  describe "signed_headers/1" do
    test "generates valid canonical form of the headers" do
      headers = [
        {"content-type", "text/plain"},
        {"host", "storage.googleapis.com"},
        {"x-goog-meta-reviewer", "jane"},
        {"x-goog-meta-reviewer", "john"}
      ]

      assert signed_headers(headers) == "content-type;host;x-goog-meta-reviewer"
    end
  end
end

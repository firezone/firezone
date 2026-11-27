defmodule PortalAPI.Sockets.SerializerTest do
  use ExUnit.Case, async: true

  alias Phoenix.Socket.{Message, Reply}
  alias PortalAPI.Sockets.Serializer

  test "sends phx_error with an empty payload" do
    message = %Message{
      topic: "gateway",
      event: "phx_error",
      ref: "1",
      join_ref: "1",
      payload: %{reason: "channel_crash"}
    }

    assert decode(Serializer.encode!(message)) == %{
             "topic" => "gateway",
             "event" => "phx_error",
             "ref" => "1",
             "payload" => %{}
           }
  end

  test "encodes other messages like the V1 serializer" do
    message = %Message{topic: "gateway", event: "init", payload: %{"a" => 1}}
    reply = %Reply{topic: "gateway", ref: "2", status: :error, payload: %{reason: "unmatched topic"}}

    assert Serializer.encode!(message) == Phoenix.Socket.V1.JSONSerializer.encode!(message)
    assert Serializer.encode!(reply) == Phoenix.Socket.V1.JSONSerializer.encode!(reply)
  end

  defp decode({:socket_push, :text, data}) do
    data |> IO.iodata_to_binary() |> JSON.decode!()
  end
end

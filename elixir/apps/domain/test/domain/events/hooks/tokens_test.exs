defmodule Domain.Events.Hooks.TokensTest do
  use ExUnit.Case, async: true
  import Domain.Events.Hooks.Tokens

  setup do
    %{old_data: %{}, data: %{}}
  end

  describe "insert/1" do
    test "returns :ok", %{data: data} do
      assert :ok == on_insert(data)
    end
  end

  describe "update/2" do
    test "does not broadcast for email token updates" do
      token_id = "token-id-123"
      topic = "sessions:#{token_id}"
      old_data = %{"id" => token_id, "type" => "email"}

      :ok = Domain.PubSub.subscribe("sessions:#{token_id}")

      assert :ok = on_update(old_data, %{})

      refute_receive %Phoenix.Socket.Broadcast{
        topic: ^topic,
        event: "disconnect"
      }
    end

    test "broadcasts disconnect for soft-deletions" do
      token_id = "token-id-123"
      topic = "sessions:#{token_id}"
      old_data = %{"id" => token_id, "deleted_at" => nil}
      data = %{"id" => token_id, "deleted_at" => DateTime.utc_now()}
      :ok = Domain.PubSub.subscribe("sessions:#{token_id}")

      assert :ok = on_update(old_data, data)

      assert_receive %Phoenix.Socket.Broadcast{
        topic: ^topic,
        event: "disconnect"
      }
    end
  end

  describe "delete/1" do
    test "broadcasts disconnect for deletions" do
      token_id = "token-id-123"
      topic = "sessions:#{token_id}"
      old_data = %{"id" => token_id}
      :ok = Domain.PubSub.subscribe("sessions:#{token_id}")

      assert :ok = on_delete(old_data)

      assert_receive %Phoenix.Socket.Broadcast{
        topic: ^topic,
        event: "disconnect"
      }
    end
  end
end

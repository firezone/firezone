defmodule Domain.Auth.AdaptersTest do
  use Domain.DataCase, async: true
  import Domain.Auth.Adapters

  # describe "update_last_signed_in/2" do
  #   test "updates last_signed_in_* fields" do
  #     actor = ActorsFixtures.create_actor(role: :admin)

  #     assert {:ok, actor} = update_last_signed_in(actor, %{provider: :test})
  #     assert actor.last_signed_in_method == "test"

  #     assert {:ok, actor} = update_last_signed_in(actor, %{provider: :another_test})
  #     assert actor.last_signed_in_method == "another_test"
  #   end
  # end
end

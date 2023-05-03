# defmodule Domain.Auth.Adapters.EmailTest do
#   use Domain.DataCase, async: true
#   import Domain.Auth.Adapters.Email

#   describe "request_sign_in_token/1" do
#     test "returns actor with updated sign-in token" do
#       actor = ActorsFixtures.create_actor(role: :admin)
#       refute actor.sign_in_token_hash

#       assert {:ok, actor} = request_sign_in_token(actor)
#       assert actor.sign_in_token
#       assert actor.sign_in_token_hash
#       assert actor.sign_in_token_created_at
#     end
#   end

#   describe "consume_sign_in_token/1" do
#     test "returns actor when token is valid" do
#       {:ok, actor} =
#         ActorsFixtures.create_actor(role: :admin)
#         |> request_sign_in_token()

#       assert {:ok, signed_in_actor} = consume_sign_in_token(actor, actor.sign_in_token)
#       assert signed_in_actor.id == actor.id
#     end

#     test "clears the sign in token when consumed" do
#       {:ok, actor} =
#         ActorsFixtures.create_actor(role: :admin)
#         |> request_sign_in_token()

#       assert {:ok, actor} = consume_sign_in_token(actor, actor.sign_in_token)
#       assert is_nil(actor.sign_in_token)
#       assert is_nil(actor.sign_in_token_created_at)

#       assert actor = Repo.one(Actors.Actor)
#       assert is_nil(actor.sign_in_token)
#       assert is_nil(actor.sign_in_token_created_at)
#     end

#     test "returns error when token doesn't exist" do
#       actor = ActorsFixtures.create_actor(role: :admin)

#       assert consume_sign_in_token(actor, "foo") == {:error, :no_token}
#     end

#     test "token expires in one hour" do
#       about_one_hour_ago =
#         DateTime.utc_now()
#         |> DateTime.add(-1, :hour)
#         |> DateTime.add(30, :second)

#       {:ok, actor} =
#         ActorsFixtures.create_actor(role: :admin)
#         |> request_sign_in_token()

#       actor
#       |> Ecto.Changeset.change(sign_in_token_created_at: about_one_hour_ago)
#       |> Repo.update!()

#       assert {:ok, _actor} = consume_sign_in_token(actor, actor.sign_in_token)
#     end

#     test "returns error when token is expired" do
#       one_hour_and_one_second_ago =
#         DateTime.utc_now()
#         |> DateTime.add(-1, :hour)
#         |> DateTime.add(-1, :second)

#       {:ok, actor} =
#         ActorsFixtures.create_actor(role: :admin)
#         |> request_sign_in_token()

#       actor =
#         actor
#         |> Ecto.Changeset.change(sign_in_token_created_at: one_hour_and_one_second_ago)
#         |> Repo.update!()

#       assert consume_sign_in_token(actor, actor.sign_in_token) == {:error, :token_expired}
#     end
#   end

# test "returns error when email is already taken", %{subject: subject, account: account} do
#   attrs = ActorsFixtures.actor_attrs()
#   assert {:ok, _actor} = create_actor(account, :unprivileged, attrs, subject)
#   assert {:error, changeset} = create_actor(account, :unprivileged, attrs, subject)
#   refute changeset.valid?
#   assert "has already been taken" in errors_on(changeset).email
# end



    # test "trims email", %{subject: subject, account: account} do
    #   attrs = ActorsFixtures.actor_attrs()
    #   updated_attrs = Map.put(attrs, :email, " #{attrs.email} ")

    #   assert {:ok, actor} = create_actor(account, :unprivileged, updated_attrs, subject)

    #   assert actor.email == attrs.email
    # end

# end

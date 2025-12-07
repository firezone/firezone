defmodule Domain.Fixtures.Relays do
  use Domain.Fixture
  import Ecto.Changeset
  alias Domain.{Relay, Tokens}

  def create_token(attrs \\ %{}) do
    attrs = Enum.into(attrs, %{})

    {account, attrs} =
      pop_assoc_fixture(attrs, :account, fn assoc_attrs ->
        Fixtures.Accounts.create_account(assoc_attrs)
      end)

    {subject, attrs} =
      pop_assoc_fixture(attrs, :subject, fn assoc_attrs ->
        assoc_attrs
        |> Enum.into(%{account: account, actor: [type: :account_admin_user]})
        |> Fixtures.Auth.create_subject()
      end)

    token_attrs = %{
      "type" => :relay,
      "secret_fragment" => Domain.Crypto.random_token(32, encoder: :hex32)
    }

    # Add account_id if we have a subject with account
    token_attrs =
      if subject do
        Map.put(token_attrs, "account_id", subject.account.id)
      else
        token_attrs
      end

    {:ok, token} =
      if subject do
        Tokens.create_token(token_attrs, subject)
      else
        Tokens.create_token(token_attrs)
      end

    encoded_token = Domain.Crypto.encode_token_fragment!(token)
    context = Fixtures.Auth.build_context(type: :relay)
    {:ok, {_account_id, _id, nonce, secret}} = Domain.Tokens.peek_token(encoded_token, context)

    %{token | secret_nonce: nonce, secret_fragment: secret}
  end

  def create_global_token(attrs \\ %{}) do
    attrs = Enum.into(attrs, %{})

    token_attrs = %{
      "type" => :relay,
      "secret_fragment" => Domain.Crypto.random_token(32, encoder: :hex32)
    }

    {:ok, token} = Tokens.create_token(token_attrs)
    encoded_token = Domain.Crypto.encode_token_fragment!(token)
    context = Fixtures.Auth.build_context(type: :relay)
    {:ok, {_account_id, _id, nonce, secret}} = Domain.Tokens.peek_token(encoded_token, context)

    %{token | secret_nonce: nonce, secret_fragment: secret}
  end

  def relay_attrs(attrs \\ %{}) do
    ipv4 = unique_ipv4()

    Enum.into(attrs, %{
      name: "relay-#{unique_integer()}",
      ipv4: ipv4,
      ipv6: unique_ipv6()
    })
  end

  def create_relay(attrs \\ %{}) do
    attrs = relay_attrs(attrs)

    {context, attrs} =
      pop_assoc_fixture(attrs, :context, fn assoc_attrs ->
        assoc_attrs
        |> Enum.into(%{type: :relay})
        |> Fixtures.Auth.build_context()
      end)

    # Create relay directly using inline logic from API.Relay.Socket
    {:ok, relay} =
      %Relay{}
      |> cast(attrs, [:name, :ipv4, :ipv6, :port])
      |> put_change(:last_seen_at, DateTime.utc_now())
      |> put_change(:last_seen_user_agent, context.user_agent)
      |> put_change(:last_seen_remote_ip, context.remote_ip)
      |> Repo.insert(
        on_conflict: {:replace, [:last_seen_at, :last_seen_user_agent, :last_seen_remote_ip]},
        conflict_target: {:unsafe_fragment, ~s/(COALESCE(ipv4, ipv6), port)/},
        returning: true
      )

    %{relay | online?: false}
  end

  def update_relay(relay, changes) do
    Ecto.Changeset.change(relay, changes)
    |> Repo.update!()
  end

  def delete_relay(relay) do
    {:ok, _} = Repo.delete(relay)
    relay
  end

  # Manually disconnects a relay for testing purposes.
  # This simulates the relay socket closing without token deletion.
  # Used to test relay presence debouncing in client/gateway channels.
  def disconnect_relay(relay) do
    # Untrack presence for the relay (only global now)
    :ok = Domain.Presence.untrack(self(), "presences:global_relays", relay.id)
    :ok = Domain.Presence.untrack(self(), "presences:relays:#{relay.id}", relay.id)

    # Unsubscribe from PubSub topics
    :ok = Domain.PubSub.unsubscribe("relays:#{relay.id}")

    :ok
  end
end

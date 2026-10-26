defmodule Portal.Workers.SignUpFollowUpTest do
  use Portal.DataCase, async: true
  use Oban.Testing, repo: Portal.Repo

  alias Portal.Workers.SignUpFollowUp
  import Portal.AccountFixtures
  import Portal.ActorFixtures

  setup do
    Portal.Config.put_env_override(:portal, SignUpFollowUp,
      from_email: "jamil@firezone.dev",
      bcc_email: "23723443@bcc.na2.hubspot.com"
    )

    account = account_fixture()
    actor = actor_fixture(account: account, type: :account_admin_user)
    %{account: account, actor: actor}
  end

  test "schedules each follow-up once per account", %{account: account, actor: actor} do
    assert :ok = SignUpFollowUp.schedule(account, actor)
    assert :ok = SignUpFollowUp.schedule(account, actor)

    assert [job, feedback_job] = all_enqueued(worker: SignUpFollowUp) |> Enum.sort_by(& &1.scheduled_at, DateTime)
    assert feedback_job.args == %{"account_id" => account.id, "actor_id" => actor.id, "stage" => "feedback"}
    assert_in_delta DateTime.diff(feedback_job.scheduled_at, DateTime.utc_now(), :second), 3 * 24 * 60 * 60, 60
    assert job.args == %{"account_id" => account.id, "actor_id" => actor.id}
    delay = DateTime.diff(job.scheduled_at, DateTime.utc_now(), :second)
    assert_in_delta delay, 15 * 60, 60
  end

  test "does not schedule when the sender is not configured", %{account: account, actor: actor} do
    Portal.Config.put_env_override(:portal, SignUpFollowUp, from_email: " ")
    assert :ok = SignUpFollowUp.schedule(account, actor)
    assert [] == all_enqueued(worker: SignUpFollowUp)
  end

  test "sends the founder email with the HubSpot BCC", %{account: account, actor: actor} do
    assert :ok = perform_job(SignUpFollowUp, %{"account_id" => account.id, "actor_id" => actor.id})

    assert_email_sent(fn email ->
      assert email.from == {"Jamil Bou Kheir", "jamil@firezone.dev"}
      assert email.to == [{"", actor.email}]
      assert email.bcc == [{"", "23723443@bcc.na2.hubspot.com"}]
      assert email.subject == "Need a hand getting started?"
      assert email.text_body =~ "I'm Jamil, one of Firezone's founders."
      assert email.html_body =~ "<p>I&#39;m Jamil, one of Firezone&#39;s founders.</p>"
      assert email.text_body =~ "Thanks for signing up! Wanted to reach out and see what you're hoping to accomplish with Firezone."
      assert email.text_body =~ "Need any help getting set up? Just reply here and I'm happy to help."
      assert_unsubscribe_link(email, actor)
      assert email.private[:account_id] == account.id
      true
    end)
  end

  test "sends the three-day feedback email", %{account: account, actor: actor} do
    assert :ok = perform_job(SignUpFollowUp, %{"account_id" => account.id, "actor_id" => actor.id, "stage" => "feedback"})

    assert_email_sent(fn email ->
      assert email.subject == "How's Firezone working out?"
      assert email.text_body =~ "Just checking in to see how things are going with Firezone."
      assert email.text_body =~ "What's working well? Anything that's been frustrating or could be better?"
      assert email.text_body =~ "We take feedback seriously, so I'd love to hear your thoughts."
      assert email.bcc == [{"", "23723443@bcc.na2.hubspot.com"}]
      assert_unsubscribe_link(email, actor)
      true
    end)
  end

  test "skips both emails when product feedback requests are turned off", %{account: account, actor: actor} do
    actor_preferences_fixture(actor, notifications: %{product_feedback_requests: []})

    for extra_args <- [%{}, %{"stage" => "feedback"}] do
      assert :ok = perform_job(SignUpFollowUp, Map.merge(%{"account_id" => account.id, "actor_id" => actor.id}, extra_args))
    end

    refute_email_sent()
  end

  test "sends without a BCC when no logging address is configured", %{
    account: account,
    actor: actor
  } do
    Portal.Config.put_env_override(:portal, SignUpFollowUp,
      from_email: "jamil@firezone.dev",
      bcc_email: nil
    )

    assert :ok = perform_job(SignUpFollowUp, %{"account_id" => account.id, "actor_id" => actor.id})

    assert_email_sent(fn email ->
      assert email.bcc == []
      true
    end)
  end

  test "skips a disabled admin", %{account: account, actor: actor} do
    {:ok, _} = actor |> Ecto.Changeset.change(is_disabled: true) |> Portal.Repo.update()
    assert :ok = perform_job(SignUpFollowUp, %{"account_id" => account.id, "actor_id" => actor.id})
    refute_email_sent()
  end

  test "skips a disabled account", %{account: account, actor: actor} do
    {:ok, _} = account |> Ecto.Changeset.change(is_disabled: true) |> Portal.Repo.update()
    assert :ok = perform_job(SignUpFollowUp, %{"account_id" => account.id, "actor_id" => actor.id})
    refute_email_sent()
  end

  test "skips delivery when the sender was removed after scheduling", %{
    account: account,
    actor: actor
  } do
    Portal.Config.put_env_override(:portal, SignUpFollowUp, from_email: nil)
    assert :ok = perform_job(SignUpFollowUp, %{"account_id" => account.id, "actor_id" => actor.id})
    refute_email_sent()
  end
  defp assert_unsubscribe_link(email, actor) do
    [token] = Regex.run(~r{/#{actor.account_id}/unsubscribe/([A-Za-z0-9_.-]+)}, email.text_body, capture: :all_but_first)
    assert {:ok, {account_id, actor_id, :product_feedback_requests}} = Portal.UnsubscribeToken.verify(token)
    assert account_id == actor.account_id
    assert actor_id == actor.id
    assert email.html_body =~ token
  end

end

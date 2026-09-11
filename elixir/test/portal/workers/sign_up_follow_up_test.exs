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

  test "schedules one job per account 15 minutes out", %{account: account, actor: actor} do
    assert :ok = SignUpFollowUp.schedule(account, actor)
    assert :ok = SignUpFollowUp.schedule(account, actor)

    assert [job] = all_enqueued(worker: SignUpFollowUp)
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
      assert email.subject == "Tell me what you think of Firezone"
      assert email.text_body =~ "I'm Jamil, Firezone's founder."
      assert email.html_body =~ "<p>I&#39;m Jamil, Firezone&#39;s founder.</p>"
      assert email.private[:account_id] == account.id
      true
    end)
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
end

defmodule Portal.Workers.RollupAccountActivityTest do
  use Portal.DataCase, async: true
  use Oban.Testing, repo: Portal.Repo

  alias Portal.AccountActivityRollup
  alias Portal.Workers.RollupAccountActivity

  import Portal.AccountFixtures
  import Portal.APIRequestLogFixtures
  import Portal.SessionLogFixtures

  defp inactive_account_fixture(attrs \\ []) do
    last_active_at = DateTime.add(DateTime.utc_now(), -400, :day)
    update_account(starter_account_fixture(), Keyword.put_new(attrs, :last_active_at, last_active_at))
  end

  defp set_processed_until(processed_until) do
    Repo.update_all(AccountActivityRollup, set: [processed_until: processed_until])
  end

  describe "perform/1" do
    test "records the latest activity and clears an older reminder" do
      now = DateTime.utc_now()
      account = inactive_account_fixture(inactivity_reminded_at: DateTime.add(now, -2, :day))
      seen_at = DateTime.add(now, -60, :second)
      session_log_fixture(account: account, context: :portal, timestamp: seen_at)

      assert :ok = perform_job(RollupAccountActivity, %{})

      account = Repo.reload!(account)
      assert account.last_active_at == seen_at
      assert is_nil(account.inactivity_reminded_at)
    end

    test "never moves activity backwards" do
      now = DateTime.utc_now()
      account = inactive_account_fixture(last_active_at: now)
      session_log_fixture(account: account, timestamp: DateTime.add(now, -60, :second))

      assert :ok = perform_job(RollupAccountActivity, %{})

      assert Repo.reload!(account).last_active_at == now
    end

    test "catches up on activity after several missed runs" do
      now = DateTime.utc_now()
      set_processed_until(DateTime.add(now, -10, :day))
      account = inactive_account_fixture()
      seen_at = DateTime.add(now, -5, :day)
      session_log_fixture(account: account, timestamp: seen_at)

      assert :ok = perform_job(RollupAccountActivity, %{})

      assert Repo.reload!(account).last_active_at == seen_at
    end

    test "records API activity from the request log" do
      account = inactive_account_fixture()
      seen_at = DateTime.add(DateTime.utc_now(), -60, :second)
      api_request_log_fixture(account: account, inserted_at: seen_at)

      assert :ok = perform_job(RollupAccountActivity, %{})

      assert Repo.reload!(account).last_active_at == seen_at
    end

    test "records accounts with a connected device" do
      account = inactive_account_fixture()

      Portal.Presence.track(
        self(),
        "presences:account_devices:" <> account.id,
        Ecto.UUID.generate(),
        %{}
      )

      assert :ok = perform_job(RollupAccountActivity, %{})

      assert DateTime.diff(DateTime.utc_now(), Repo.reload!(account).last_active_at) < 5
    end

    test "restarts the observation period after a gap longer than log retention" do
      now = DateTime.utc_now()
      account = inactive_account_fixture(inactivity_reminded_at: DateTime.add(now, -15, :day))
      set_processed_until(DateTime.add(now, -122, :day))

      assert :ok = perform_job(RollupAccountActivity, %{})

      account = Repo.reload!(account)
      assert DateTime.diff(DateTime.utc_now(), account.last_active_at) < 5
      assert is_nil(account.inactivity_reminded_at)
      assert RollupAccountActivity.current?(DateTime.utc_now())
    end
  end

  describe "refresh/2" do
    test "records activity newer than the reminder and clears it" do
      now = DateTime.utc_now()
      account = inactive_account_fixture(inactivity_reminded_at: DateTime.add(now, -2, :day))
      seen_at = DateTime.add(now, -60, :second)
      session_log_fixture(account: account, timestamp: seen_at)

      account = RollupAccountActivity.refresh(account, now)

      assert account.last_active_at == seen_at
      assert is_nil(account.inactivity_reminded_at)
    end

    test "keeps the reminder when the only activity is older than it" do
      now = DateTime.utc_now()
      reminded_at = DateTime.add(now, -2, :day)
      account = inactive_account_fixture(inactivity_reminded_at: reminded_at)
      session_log_fixture(account: account, timestamp: DateTime.add(now, -3, :day))

      account = RollupAccountActivity.refresh(account, now)

      assert account.inactivity_reminded_at == reminded_at
    end
  end

  describe "current?/1" do
    test "is false when the rollup has not run for two days" do
      now = DateTime.utc_now()
      assert RollupAccountActivity.current?(now)

      set_processed_until(DateTime.add(now, -3, :day))

      refute RollupAccountActivity.current?(now)
    end
  end
end

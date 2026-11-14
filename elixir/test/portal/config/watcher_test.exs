defmodule Portal.Config.WatcherTest do
  use ExUnit.Case, async: true
  alias Portal.Config.Watcher

  setup do
    app = :"watcher_test_#{System.unique_integer([:positive])}"
    {:ok, storage} = Agent.start_link(fn -> nil end)
    on_exit(fn ->
      for key <- [:feedback, :mailer], do: Application.delete_env(app, key)
    end)
    %{app: app, storage: storage}
  end

  defp settings(pairs) do
    Map.new(pairs, fn {key, value, mode} -> {key, %{value: value, mode: mode}} end)
  end

  # Mirrors runtime.exs: application env derived from whatever settings are
  # current at the time it is evaluated.
  defp state(%{app: app, storage: storage}, latest, opts \\ []) do
    %{
      fetch: Keyword.get(opts, :fetch, fn -> latest end),
      get_settings: fn -> Agent.get(storage, & &1) end,
      put_settings: fn settings -> Agent.update(storage, fn _ -> settings end) end,
      read_config:
        Keyword.get(opts, :read_config, fn ->
          current = Agent.get(storage, & &1)

          [
            {app,
             [
               feedback: current["FEEDBACK_EMAIL_RECIPIENT"].value,
               mailer: [adapter: :acs]
             ]}
          ]
        end)
    }
  end

  defp boot_with(%{storage: storage, app: app}, settings) do
    Agent.update(storage, fn _ -> settings end)
    Application.put_env(app, :feedback, settings["FEEDBACK_EMAIL_RECIPIENT"].value)
    Application.put_env(app, :mailer, adapter: :acs)
  end

  test "does nothing when the store has not changed", context do
    current = settings([{"FEEDBACK_EMAIL_RECIPIENT", "a@example.com", :live}])
    boot_with(context, current)

    assert Watcher.reload(state(context, current)) == :unchanged
  end

  test "applies a live change", %{app: app} = context do
    boot_with(context, settings([{"FEEDBACK_EMAIL_RECIPIENT", "a@example.com", :live}]))
    latest = settings([{"FEEDBACK_EMAIL_RECIPIENT", "b@example.com", :live}])

    assert Watcher.reload(state(context, latest)) == :applied
    assert Application.get_env(app, :feedback) == "b@example.com"
    assert Agent.get(context.storage, & &1) == latest
  end

  test "keeps manual overrides the live change does not touch", %{app: app} = context do
    boot_with(context, settings([{"FEEDBACK_EMAIL_RECIPIENT", "a@example.com", :live}]))
    Application.put_env(app, :mailer, adapter: :resend)
    latest = settings([{"FEEDBACK_EMAIL_RECIPIENT", "b@example.com", :live}])

    assert Watcher.reload(state(context, latest)) == :applied
    assert Application.get_env(app, :mailer) == [adapter: :resend]
  end

  test "keeps a manual override next to a changed key in the same entry", %{app: app} = context do
    current = settings([{"OUTBOUND_EMAIL_FROM", "a@example.com", :live}])
    Agent.update(context.storage, fn _ -> current end)
    Application.put_env(app, :mailer, adapter: :resend, from_email: "a@example.com")
    latest = settings([{"OUTBOUND_EMAIL_FROM", "b@example.com", :live}])

    read_config = fn ->
      settings = Agent.get(context.storage, & &1)
      [{app, [mailer: [adapter: :acs, from_email: settings["OUTBOUND_EMAIL_FROM"].value]]}]
    end

    assert Watcher.reload(state(context, latest, read_config: read_config)) == :applied
    assert Application.get_env(app, :mailer) == [adapter: :resend, from_email: "b@example.com"]
  end

  test "waits for a restart when a boot setting changed", %{app: app} = context do
    current =
      settings([
        {"FEEDBACK_EMAIL_RECIPIENT", "a@example.com", :live},
        {"DATABASE_HOST", "10.0.0.4", :boot}
      ])

    boot_with(context, current)

    latest =
      settings([
        {"FEEDBACK_EMAIL_RECIPIENT", "b@example.com", :live},
        {"DATABASE_HOST", "10.0.0.5", :boot}
      ])

    assert Watcher.reload(state(context, latest)) == :restart_required
    assert Application.get_env(app, :feedback) == "a@example.com"
    assert Agent.get(context.storage, & &1) == current
  end

  test "keeps the current settings when the new ones do not evaluate", %{app: app} = context do
    current = settings([{"FEEDBACK_EMAIL_RECIPIENT", "a@example.com", :live}])
    boot_with(context, current)
    latest = settings([{"FEEDBACK_EMAIL_RECIPIENT", "not an email", :live}])

    read_config = fn ->
      case Agent.get(context.storage, & &1) do
        %{"FEEDBACK_EMAIL_RECIPIENT" => %{value: "not an email"}} -> raise "invalid recipient"
        settings -> [{app, [feedback: settings["FEEDBACK_EMAIL_RECIPIENT"].value]}]
      end
    end

    assert Watcher.reload(state(context, latest, read_config: read_config)) == :rejected
    assert Application.get_env(app, :feedback) == "a@example.com"
    assert Agent.get(context.storage, & &1) == current
  end

  test "keeps the current settings when the store cannot be read", context do
    current = settings([{"FEEDBACK_EMAIL_RECIPIENT", "a@example.com", :live}])
    boot_with(context, current)

    assert Watcher.reload(state(context, nil, fetch: fn -> raise "HTTP 503" end)) == :error
    assert Agent.get(context.storage, & &1) == current
  end
end

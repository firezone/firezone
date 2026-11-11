defmodule Portal.DisposableEmailHelpers do
  @moduledoc """
  Loads disposable email domain lists from `file://` URLs for one test, in a
  `Portal.DisposableEmail.Lists` process of its own so async tests don't share lists.
  """
  import ExUnit.Callbacks

  @doc """
  Writes the lists to temporary files, starts a `Portal.DisposableEmail.Lists` process that
  loads them and points `Portal.DisposableEmail` at it. Returns the process name and the paths.
  """
  def use_disposable_email_lists(lists, opts \\ []) do
    name = :"disposable_email_lists_#{System.unique_integer([:positive])}"
    dir = Path.join(System.tmp_dir!(), Atom.to_string(name))
    File.mkdir_p!(dir)

    paths =
      Map.new(lists, fn {kind, domains} ->
        path = Path.join(dir, "#{kind}.txt")
        File.write!(path, Enum.join(domains, "\n"))
        {kind, path}
      end)

    on_exit(fn ->
      File.rm_rf!(dir)
      Enum.each([:confirmed, :suspected], &:persistent_term.erase({Portal.DisposableEmail.Lists, name, &1}))
    end)

    start_supervised!(
      {Portal.DisposableEmail.Lists,
       Keyword.merge(
         [
           name: name,
           confirmed_url: paths[:confirmed] && "file://" <> paths[:confirmed],
           suspected_url: paths[:suspected] && "file://" <> paths[:suspected],
           refresh_interval: :timer.hours(1)
         ],
         opts
       )},
      id: name
    )

    # Waits for the initial load, which runs after start_supervised!/2 returns.
    :sys.get_state(name)
    put_config(:lists, name)

    {name, paths}
  end

  @doc """
  Answers MX lookups with `fun.(domain)`.
  """
  def stub_mx(fun), do: put_config(:mx_lookup, fun)

  # Each override replaces the previous one, so keep what an earlier helper call set.
  defp put_config(key, value) do
    config = Portal.Config.get_env(:portal, Portal.DisposableEmail)
    Portal.Config.put_env_override(:portal, Portal.DisposableEmail, Keyword.put(config, key, value))
  end
end

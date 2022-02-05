case System.cmd(Path.join([__DIR__, "semver.sh"]), [], stderr_to_stdout: true) do
  {result, 0} ->
    result |> String.trim()

  {_error, _exit_code} ->
    "0.0.0+git.0.deadbeef"
end

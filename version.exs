case System.cmd(Path.join([__DIR__, "scripts", "semver.sh"]), []) do
  {result, 0} ->
    result |> String.trim()

  {_, _} ->
    "0.0.0"
end

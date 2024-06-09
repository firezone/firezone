case File.read(Path.join([__DIR__, "GIT_SHA"])) do
  {:ok, sha} ->
    sha |> String.trim

  _ ->
    "deadbeef"
end

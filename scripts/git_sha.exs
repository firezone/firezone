{result, 0} = System.cmd(Path.join([__DIR__, "git_sha.sh"]), [], stderr_to_stdout: true)
result |> String.trim()

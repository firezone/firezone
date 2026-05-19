defmodule Credo.Check.Warning.UnsafeRepoUsageTest do
  use ExUnit.Case, async: true

  alias Credo.Check.Warning.UnsafeRepoUsage

  setup_all do
    Application.ensure_all_started(:credo)
    :ok
  end

  test "reports direct Portal.Repo calls in application code" do
    issues =
      """
      defmodule Portal.Example do
        def list do
          Portal.Repo.all(Portal.Account)
        end
      end
      """
      |> source_file("lib/portal/example.ex")
      |> UnsafeRepoUsage.run()

    assert [%{trigger: "Portal.Repo", line_no: 3}] = issues
  end

  test "reports direct Repo calls in non-infrastructure lib/portal/repo files" do
    issues =
      """
      defmodule Portal.Repo.Batch do
        alias Portal.Repo

        def list do
          Repo.all(Portal.Account)
        end
      end
      """
      |> source_file("lib/portal/repo/batch.ex")
      |> UnsafeRepoUsage.run()

    assert Enum.map(issues, & &1.line_no) == [5, 2]
  end

  test "allows direct Repo usage in Portal.Repo infrastructure files" do
    issues =
      """
      defmodule Portal.Repo do
        alias Portal.Repo

        def list do
          Repo.all(Portal.Account)
        end
      end
      """
      |> source_file("lib/portal/repo.ex")
      |> UnsafeRepoUsage.run()

    assert issues == []
  end

  test "allows Portal.Repo preload usage in preloader infrastructure" do
    issues =
      """
      defmodule Portal.Repo.Preloader do
        def preload(results, preload) do
          Portal.Repo.preload(results, preload)
        end
      end
      """
      |> source_file("lib/portal/repo/preloader.ex")
      |> UnsafeRepoUsage.run()

    assert issues == []
  end

  defp source_file(source, filename) do
    Credo.SourceFile.parse(source, filename)
  end
end

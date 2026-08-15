defmodule Credo.Check.Warning.AsyncFalseInTestTest do
  use ExUnit.Case, async: true

  alias Credo.Check.Warning.AsyncFalseInTest

  setup_all do
    Application.ensure_all_started(:credo)
    :ok
  end

  test "reports async: false in an ExUnit case" do
    issues =
      """
      defmodule Portal.ExampleTest do
        use ExUnit.Case, async: false
      end
      """
      |> issues()

    assert [%{trigger: "async: false", line_no: 2}] = issues
  end

  test "reports async: false in a custom case template" do
    issues =
      """
      defmodule PortalWeb.ExampleTest do
        use PortalWeb.ConnCase,
          async: false
      end
      """
      |> issues()

    assert [%{trigger: "async: false", line_no: 2}] = issues
  end

  test "allows async: true" do
    issues =
      """
      defmodule Portal.ExampleTest do
        use ExUnit.Case, async: true
      end
      """
      |> issues()

    assert issues == []
  end

  test "ignores unrelated async options" do
    issues =
      """
      defmodule Portal.ExampleTest do
        def request, do: run(async: false)
      end
      """
      |> issues()

    assert issues == []
  end

  test "ignores non-test files" do
    issues =
      """
      defmodule Portal.Example do
        use ExUnit.Case, async: false
      end
      """
      |> issues("lib/portal/example.ex")

    assert issues == []
  end

  defp issues(source, filename \\ "test/portal/example_test.exs") do
    source
    |> Credo.SourceFile.parse(filename)
    |> AsyncFalseInTest.run()
  end
end

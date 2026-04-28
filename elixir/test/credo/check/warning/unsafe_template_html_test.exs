defmodule Credo.Check.Warning.UnsafeTemplateHTMLTest do
  use ExUnit.Case, async: true

  alias Credo.Check.Warning.UnsafeTemplateHTML

  @moduletag :tmp_dir

  setup_all do
    Application.ensure_all_started(:credo)
    :ok
  end

  test "reports HTML-safe markers in EEx tags", %{tmp_dir: tmp_dir} do
    write_template!(tmp_dir, """
    <%= raw(@name) %>
    <%= Phoenix.HTML.raw(@name) %>
    <%== @name %>
    <%= {:safe, @name} %>
    <%= Phoenix.HTML.Safe.to_iodata(@name) %>
    <%= safe_to_string(@name) %>
    <%= Phoenix.HTML.safe_to_string(@name) %>
    """)

    issues = issues(tmp_dir)

    assert Enum.map(issues, & &1.trigger) == [
             "raw",
             "Phoenix.HTML.raw",
             "<%==",
             "{:safe,",
             "Phoenix.HTML.Safe",
             "safe_to_string",
             "Phoenix.HTML.safe_to_string"
           ]

    assert Enum.map(issues, & &1.line_no) == [1, 2, 3, 4, 5, 6, 7]
    assert Enum.all?(issues, &String.ends_with?(&1.filename, "email.html.eex"))
  end

  test "reports HTML-safe markers in HEEx expressions", %{tmp_dir: tmp_dir} do
    write_template!(tmp_dir, "page.html.heex", """
    <div>{Phoenix.HTML.raw(@name)}</div>
    <div>{raw(@name)}</div>
    <div>{ {:safe, @name} }</div>
    <div>{Phoenix.HTML.Safe.to_iodata(@name)}</div>
    <div>{safe_to_string(@name)}</div>
    <div>{Phoenix.HTML.safe_to_string(@name)}</div>
    """)

    issues = issues(tmp_dir)

    assert Enum.map(issues, & &1.trigger) == [
             "Phoenix.HTML.raw",
             "raw",
             "{:safe,",
             "Phoenix.HTML.Safe",
             "safe_to_string",
             "Phoenix.HTML.safe_to_string"
           ]

    assert Enum.map(issues, & &1.line_no) == [1, 2, 3, 4, 5, 6]
    assert Enum.all?(issues, &String.ends_with?(&1.filename, "page.html.heex"))
  end

  test "ignores literal HTML text and EEx comments", %{tmp_dir: tmp_dir} do
    write_template!(tmp_dir, """
    raw(
    <%# raw(@name) %>
    <%= @name %>
    """)

    assert issues(tmp_dir) == []
  end

  test "supports EEx disable comments for the next line", %{tmp_dir: tmp_dir} do
    write_template!(tmp_dir, """
    <%# credo:disable-for-next-line Credo.Check.Warning.UnsafeTemplateHTML %>
    <%= raw(@name) %>
    <%= raw(@other_name) %>
    """)

    assert [%{line_no: 3, trigger: "raw"}] = issues(tmp_dir)
  end

  test "supports EEx disable comments for the whole file", %{tmp_dir: tmp_dir} do
    write_template!(tmp_dir, """
    <%# credo:disable-for-this-file Credo.Check.Warning.UnsafeTemplateHTML %>
    <%= raw(@name) %>
    <%== @name %>
    """)

    assert issues(tmp_dir) == []
  end

  test "supports HEEx disable comments", %{tmp_dir: tmp_dir} do
    write_template!(tmp_dir, "page.html.heex", """
    <%!-- credo:disable-for-next-line Credo.Check.Warning.UnsafeTemplateHTML --%>
    <div>{raw(@name)}</div>
    <div>{raw(@other_name)}</div>
    """)

    assert [%{line_no: 3, trigger: "raw"}] = issues(tmp_dir)
  end

  defp issues(tmp_dir) do
    UnsafeTemplateHTML.template_issues(
      source_file(),
      template_globs: [
        Path.join(tmp_dir, "*.html.eex"),
        Path.join(tmp_dir, "*.html.heex")
      ]
    )
  end

  defp source_file do
    Credo.SourceFile.parse(
      """
      defmodule TestSource do
      end
      """,
      "lib/test_source.ex"
    )
  end

  defp write_template!(tmp_dir, contents) do
    write_template!(tmp_dir, "email.html.eex", contents)
  end

  defp write_template!(tmp_dir, filename, contents) do
    path = Path.join(tmp_dir, filename)
    File.write!(path, contents)
  end
end

defmodule PortalWeb.LiveTableTest do
  use PortalWeb.ConnCase, async: true
  import PortalWeb.LiveTable
  import Portal.SubjectFixtures

  describe "<.live_table /> component" do
    setup do
      assigns = %{
        id: "table-id",
        filters: [],
        filter: filter_to_form(%{}, "table-id"),
        ordered_by: {:assoc, :name},
        metadata: %{
          previous_page_cursor: nil,
          next_page_cursor: nil,
          limit: 10,
          count: 1
        },
        col: [
          %{
            label: "name",
            field: {:assoc, :name},
            inner_block: fn _col, row ->
              row
            end
          }
        ],
        rows: ["foo"]
      }

      %{assigns: assigns}
    end

    test "renders a data table", %{assigns: assigns} do
      html = render_component(&live_table/1, assigns)

      assert html
             |> Floki.parse_fragment!()
             |> Floki.find("table")
             |> Floki.attribute("id") == ["table-id"]

      assert html
             |> Floki.parse_fragment!()
             |> Floki.find("table thead")
             |> Floki.attribute("id") == ["table-id-header"]

      assert html
             |> Floki.parse_fragment!()
             |> Floki.find("th")
             |> Floki.text() =~ "name"

      assert html
             |> Floki.parse_fragment!()
             |> Floki.find("table tbody")
             |> Floki.attribute("id") == ["table-id-rows"]

      assert html
             |> Floki.parse_fragment!()
             |> Floki.find("td")
             |> Floki.text() =~ "foo"
    end

    test "renders fulltext search filter", %{assigns: assigns} do
      assigns = %{
        assigns
        | filters: [
            %Portal.Repo.Filter{
              name: :search,
              title: "Query",
              type: {:string, :websearch}
            }
          ],
          filter: filter_to_form(%{search: "foo"}, "table-id")
      }

      form =
        render_component(&live_table/1, assigns)
        |> Floki.parse_fragment!()
        |> Floki.find("form")

      assert Floki.attribute(form, "id") == ["table-id-filters"]
      assert Floki.attribute(form, "phx-change") == ["filter"]

      input = form |> Floki.find("input[type=hidden]")
      assert Floki.attribute(input, "name") == ["table_id"]
      assert Floki.attribute(input, "value") == ["table-id"]

      input = form |> Floki.find("input[type=text]")
      assert Floki.attribute(input, "id") == ["table-id_search"]
      assert Floki.attribute(input, "name") == ["table-id[search]"]
      assert Floki.attribute(input, "placeholder") == ["Search by Query"]
      assert Floki.attribute(input, "value") == ["foo"]
    end

    test "renders email filter", %{assigns: assigns} do
      assigns = %{
        assigns
        | filters: [
            %Portal.Repo.Filter{
              name: :email,
              title: "Email",
              type: {:string, :email}
            }
          ],
          filter: filter_to_form(%{email: "foo@bar.com"}, "table-id")
      }

      form =
        render_component(&live_table/1, assigns)
        |> Floki.parse_fragment!()
        |> Floki.find("form")

      assert Floki.attribute(form, "id") == ["table-id-filters"]
      assert Floki.attribute(form, "phx-change") == ["filter"]

      input = form |> Floki.find("input[type=hidden]")
      assert Floki.attribute(input, "name") == ["table_id"]
      assert Floki.attribute(input, "value") == ["table-id"]

      input = form |> Floki.find("input[type=text]")
      assert Floki.attribute(input, "id") == ["table-id_email"]
      assert Floki.attribute(input, "name") == ["table-id[email]"]
      assert Floki.attribute(input, "placeholder") == ["Search by Email"]
      assert Floki.attribute(input, "value") == ["foo@bar.com"]
    end

    test "renders UUID dropdown filter", %{assigns: assigns} do
      assigns = %{
        assigns
        | filters: [
            %Portal.Repo.Filter{
              name: :id,
              title: "ID",
              type: {:string, :uuid},
              values: [
                {"group1", [{"One", "1"}]},
                {"group1", [{"Two", "2"}]},
                {nil, [{"Three", "3"}]}
              ]
            }
          ],
          filter: filter_to_form(%{id: "1"}, "table-id")
      }

      form =
        render_component(&live_table/1, assigns)
        |> Floki.parse_fragment!()
        |> Floki.find("form")

      assert Floki.attribute(form, "id") == ["table-id-filters"]
      assert Floki.attribute(form, "phx-change") == ["filter"]

      input = form |> Floki.find("input[type=hidden]")
      assert Floki.attribute(input, "name") == ["table_id"]
      assert Floki.attribute(input, "value") == ["table-id"]

      select = form |> Floki.find("select")
      assert Floki.attribute(select, "id") == ["table-id_id"]
      assert Floki.attribute(select, "name") == ["table-id[id]"]

      assert select |> List.first() |> elem(2) == [
               {"option", [{"value", ""}], ["For any ID"]},
               {"optgroup", [{"label", "group1"}],
                [{"option", [{"selected", "selected"}, {"value", "1"}], ["One"]}]},
               {"optgroup", [{"label", "group1"}], [{"option", [{"value", "2"}], ["Two"]}]},
               {"option", [{"value", "3"}], ["Three"]}
             ]
    end

    test "renders radio buttons for select from up to 5 values", %{assigns: assigns} do
      assigns = %{
        assigns
        | filters: [
            %Portal.Repo.Filter{
              name: :btn,
              title: "Button",
              type: :string,
              values: [
                {"One", "1"},
                {"Two", "2"}
              ]
            }
          ],
          filter: filter_to_form(%{id: "1"}, "table-id")
      }

      form =
        render_component(&live_table/1, assigns)
        |> Floki.parse_fragment!()
        |> Floki.find("form")

      assert Floki.attribute(form, "id") == ["table-id-filters"]
      assert Floki.attribute(form, "phx-change") == ["filter"]

      input = form |> Floki.find("input[type=hidden]")
      assert Floki.attribute(input, "name") == ["table_id"]
      assert Floki.attribute(input, "value") == ["table-id"]

      radio = form |> Floki.find("input[type=radio]")

      assert Floki.attribute(radio, "id") == [
               "table-id-btn-__all__",
               "table-id-btn-1",
               "table-id-btn-2"
             ]

      assert Floki.attribute(radio, "name") == [
               "_reset:table-id[btn]",
               "table-id[btn]",
               "table-id[btn]"
             ]

      assert Floki.attribute(radio, "value") == [
               "true",
               "1",
               "2"
             ]
    end

    test "renders value dropdown when there are more than 5 values", %{assigns: assigns} do
      assigns = %{
        assigns
        | filters: [
            %Portal.Repo.Filter{
              name: :select,
              title: "Select",
              type: :string,
              values: [
                {"One", "1"},
                {"Two", "2"},
                {"Three", "3"},
                {"Four", "4"},
                {"Five", "5"},
                {"Six", "6"}
              ]
            }
          ],
          filter: filter_to_form(%{id: "1"}, "table-id")
      }

      form =
        render_component(&live_table/1, assigns)
        |> Floki.parse_fragment!()
        |> Floki.find("form")

      assert Floki.attribute(form, "id") == ["table-id-filters"]
      assert Floki.attribute(form, "phx-change") == ["filter"]

      input = form |> Floki.find("input[type=hidden]")
      assert Floki.attribute(input, "name") == ["table_id"]
      assert Floki.attribute(input, "value") == ["table-id"]

      select = form |> Floki.find("select")
      assert Floki.attribute(select, "id") == ["table-id_select"]
      assert Floki.attribute(select, "name") == ["table-id[select]"]

      assert select |> List.first() |> elem(2) == [
               {"option", [{"value", ""}], ["For any Select"]},
               {"option", [{"value", "1"}], ["One"]},
               {"option", [{"value", "2"}], ["Two"]},
               {"option", [{"value", "3"}], ["Three"]},
               {"option", [{"value", "4"}], ["Four"]},
               {"option", [{"value", "5"}], ["Five"]},
               {"option", [{"value", "6"}], ["Six"]}
             ]
    end

    test "renders ordering buttons", %{assigns: assigns} do
      # default order when it's unset
      html = render_component(&live_table/1, assigns)
      order_button = html |> Floki.parse_fragment!() |> Floki.find("th button")
      assert Floki.attribute(order_button, "phx-click") == ["order_by"]
      assert Floki.attribute(order_button, "phx-value-table_id") == ["table-id"]
      assert Floki.attribute(order_button, "phx-value-order_by") == ["assoc:asc:name"]

      # current order if it's set
      assigns = %{assigns | ordered_by: {:assoc, :desc, :name}}
      html = render_component(&live_table/1, assigns)
      order_button = html |> Floki.parse_fragment!() |> Floki.find("th button")
      assert Floki.attribute(order_button, "phx-value-order_by") == ["assoc:desc:name"]
    end

    test "renders page size and total count", %{assigns: assigns} do
      assert render_component(&live_table/1, assigns)
             |> Floki.parse_fragment!()
             |> Floki.find("nav > span")
             |> Floki.text()
             |> String.replace(~r/[\s]+/, " ") =~ "Showing 1 of 1"

      assert render_component(&live_table/1, %{
               assigns
               | metadata: %{assigns.metadata | count: 10, limit: 100},
                 rows: Enum.map(1..10, fn _i -> ["foo"] end)
             })
             |> Floki.parse_fragment!()
             |> Floki.find("nav > span")
             |> Floki.text()
             |> String.replace(~r/[\s]+/, " ") =~ "Showing 10 of 10"

      assert render_component(&live_table/1, %{
               assigns
               | metadata: %{assigns.metadata | count: 100, limit: 10},
                 rows: Enum.map(1..100, fn _i -> ["foo"] end)
             })
             |> Floki.parse_fragment!()
             |> Floki.find("nav > span")
             |> Floki.text()
             |> String.replace(~r/[\s]+/, " ") =~ "Showing 100 of 100"
    end

    test "renders pagination buttons", %{assigns: assigns} do
      html = render_component(&live_table/1, assigns)

      assert html
             |> Floki.parse_fragment!()
             |> Floki.find("nav button")
             |> Floki.attribute("disabled") == ["disabled", "disabled"]

      assigns = %{assigns | metadata: %{assigns.metadata | next_page_cursor: "next_cursor"}}
      html = render_component(&live_table/1, assigns)

      assert html
             |> Floki.parse_fragment!()
             |> Floki.find("nav button")
             |> Floki.attribute("disabled") == ["disabled"]

      enabled_button = html |> Floki.parse_fragment!() |> Floki.find("nav button:not([disabled])")
      assert Floki.attribute(enabled_button, "phx-click") == ["paginate"]
      assert Floki.attribute(enabled_button, "phx-value-cursor") == ["next_cursor"]
      assert Floki.attribute(enabled_button, "phx-value-table_id") == ["table-id"]

      assigns = %{assigns | metadata: %{assigns.metadata | previous_page_cursor: "prev_cursor"}}
      html = render_component(&live_table/1, assigns)

      assert html
             |> Floki.parse_fragment!()
             |> Floki.find("nav button")
             |> Floki.attribute("disabled") == []

      enabled_button = html |> Floki.parse_fragment!() |> Floki.find("nav button:not([disabled])")
      assert "prev_cursor" in Floki.attribute(enabled_button, "phx-value-cursor")
    end

    test "does not render pagination when table is empty", %{assigns: assigns} do
      assigns = %{assigns | rows: []}
      html = render_component(&live_table/1, assigns)

      # Should not find any nav element for pagination
      assert html
             |> Floki.parse_fragment!()
             |> Floki.find("nav[aria-label='Table navigation']") == []
    end
  end

  describe "assign_live_table/3" do
    setup do
      subject = subject_fixture()
      socket = %Phoenix.LiveView.Socket{assigns: %{subject: subject, __changed__: %{}}}
      %{socket: socket}
    end

    test "persists live table state in the socket", %{socket: socket} do
      assert %{
               assigns: %{
                 __changed__: %{
                   live_table_ids: true,
                   callback_by_table_id: true,
                   sortable_fields_by_table_id: true,
                   filters_by_table_id: true,
                   enforced_filters_by_table_id: true,
                   limit_by_table_id: true
                 },
                 live_table_ids: ["table-id"],
                 callback_by_table_id: %{"table-id" => _fun},
                 sortable_fields_by_table_id: %{"table-id" => [actors: :name]},
                 filters_by_table_id: %{"table-id" => []},
                 enforced_filters_by_table_id: %{},
                 limit_by_table_id: %{}
               }
             } =
               assign_live_table(socket, "table-id",
                 query_module: Actor.Query,
                 sortable_fields: [
                   {:actors, :name}
                 ],
                 callback: fn socket, list_opts ->
                   {:ok, %{socket | private: %{list_opts: list_opts}}}
                 end
               )

      assert %{
               assigns: %{
                 __changed__: %{
                   live_table_ids: true,
                   callback_by_table_id: true,
                   sortable_fields_by_table_id: true,
                   filters_by_table_id: true,
                   enforced_filters_by_table_id: true,
                   limit_by_table_id: true
                 },
                 live_table_ids: ["table-id"],
                 callback_by_table_id: %{"table-id" => _fun},
                 sortable_fields_by_table_id: %{"table-id" => [actors: :name]},
                 filters_by_table_id: %{"table-id" => []},
                 enforced_filters_by_table_id: %{"table-id" => [name: "foo"]},
                 limit_by_table_id: %{"table-id" => 11}
               }
             } =
               assign_live_table(socket, "table-id",
                 query_module: Actor.Query,
                 sortable_fields: [
                   {:actors, :name}
                 ],
                 enforce_filters: [
                   {:name, "foo"}
                 ],
                 hide_filters: [:email],
                 limit: 11,
                 callback: fn socket, list_opts ->
                   {:ok, %{socket | private: %{list_opts: list_opts}}}
                 end
               )
    end
  end

  describe "reload_live_table!/2" do
    test "reloads the live table" do
      subject = subject_fixture()

      socket =
        %Phoenix.LiveView.Socket{
          assigns: %{subject: subject, __changed__: %{}}
        }
        |> assign_live_table("table-id",
          query_module: Actor.Query,
          sortable_fields: [
            {:actors, :name}
          ],
          callback: fn socket, list_opts ->
            {:ok, %{socket | private: %{list_opts: list_opts}}}
          end
        )

      assert %{
               private: %{list_opts: []}
             } = reload_live_table!(socket, "table-id")
    end

    test "reloads whole page on errors" do
      subject = subject_fixture()

      socket =
        %Phoenix.LiveView.Socket{
          assigns: %{subject: subject, __changed__: %{}}
        }
        |> put_uri_assigns("/current_uri")
        |> assign_live_table("table-id",
          query_module: Actor.Query,
          sortable_fields: [
            {:actors, :name}
          ],
          callback: fn _socket, _list_opts -> {:error, :not_found} end
        )

      assert %{
               redirected: {:live, :redirect, %{kind: :push, to: "/current_uri"}}
             } = reload_live_table!(socket, "table-id")
    end
  end

  describe "handle_live_tables_params/3" do
    setup do
      subject = subject_fixture()

      test_pid = self()

      socket =
        %Phoenix.LiveView.Socket{
          assigns: %{subject: subject, __changed__: %{}}
        }
        |> put_uri_assigns("/actors")
        |> assign_live_table("table-id",
          query_module: Actor.Query,
          sortable_fields: [
            {:actors, :name}
          ],
          callback: fn socket, list_opts ->
            send(test_pid, {:callback, socket, list_opts})
            {:ok, %{socket | private: %{list_opts: list_opts}}}
          end
        )

      %{socket: socket}
    end

    test "assigns the live table data from callbacks", %{socket: socket} do
      assert %{
               assigns: %{
                 current_path: "/actors"
               },
               private: %{
                 list_opts: [
                   page: [limit: 10],
                   filter: [],
                   order_by: []
                 ]
               }
             } = handle_live_tables_params(socket, %{}, "/actors")

      assert %{
               assigns: %{
                 current_path: "/actors"
               },
               private: %{
                 list_opts: [
                   page: [cursor: "next_page", limit: 10],
                   filter: [{:name, "foo"}],
                   order_by: [{:actors, :asc, :name}]
                 ]
               }
             } =
               handle_live_tables_params(
                 socket,
                 %{
                   "table-id_cursor" => "next_page",
                   "table-id_filter" => %{"name" => "foo"},
                   "table-id_order_by" => "actors:asc:name"
                 },
                 "/actors"
               )
    end

    test "does nothing when list opts are not changed", %{socket: socket} do
      socket = handle_live_tables_params(socket, %{}, "/actors")
      assert_receive {:callback, _socket, [page: [limit: 10], filter: [], order_by: []]}

      handle_live_tables_params(socket, %{}, "/actors")
      refute_receive {:callback, _socket, _list_opts}
    end

    test "raises if the table params are invalid" do
      subject = subject_fixture()

      socket =
        %Phoenix.LiveView.Socket{
          assigns: %{subject: subject, __changed__: %{}, flash: %{}}
        }
        |> put_uri_assigns("/current_uri")

      for {reason, message} <- [
            {:invalid_cursor, "The page was reset due to invalid pagination cursor."},
            {{:unknown_filter, []},
             "The page was reset due to use of undefined pagination filter."},
            {{:invalid_type, []},
             "The page was reset due to invalid value of a pagination filter."},
            {{:invalid_value, []},
             "The page was reset due to invalid value of a pagination filter."}
          ] do
        socket =
          assign_live_table(socket, "table-id",
            query_module: Actor.Query,
            sortable_fields: [
              {:actors, :name}
            ],
            callback: fn _socket, _list_opts -> {:error, reason} end
          )

        socket = handle_live_tables_params(socket, %{}, "/foo")
        assert socket.assigns.flash == %{"error" => message}
      end
    end

    test "raises if the callback returns a generic error" do
      subject = subject_fixture()

      socket =
        %Phoenix.LiveView.Socket{
          assigns: %{subject: subject, __changed__: %{}}
        }
        |> put_uri_assigns("/current_uri")

      for {reason, exception} <- [
            {:not_found, PortalWeb.LiveErrors.NotFoundError},
            {:unauthorized, PortalWeb.LiveErrors.NotFoundError}
          ] do
        socket =
          assign_live_table(socket, "table-id",
            query_module: Actor.Query,
            sortable_fields: [
              {:actors, :name}
            ],
            callback: fn _socket, _list_opts -> {:error, reason} end
          )

        assert_raise exception, fn ->
          handle_live_tables_params(socket, %{}, "/foo")
        end
      end
    end
  end

  describe "handle_live_table_event/3 for pagination" do
    setup do
      subject = subject_fixture()

      socket =
        %Phoenix.LiveView.Socket{
          assigns: %{subject: subject, __changed__: %{}}
        }
        |> put_uri_assigns(
          "/actors?table-id_cursor=prev_page" <>
            "&table-id_filter%5Bname%5D=buz" <>
            "&table-id_order_by=actors%3Aasc%3Aname"
        )
        |> assign_live_table("table-id",
          query_module: Actor.Query,
          sortable_fields: [
            {:actors, :name}
          ],
          callback: fn socket, list_opts ->
            {:ok, %{socket | private: %{list_opts: list_opts}}}
          end
        )

      %{socket: socket}
    end

    test "updates query parameters with new cursor", %{socket: socket} do
      assert handle_live_table_event(
               "paginate",
               %{"table_id" => "table-id", "cursor" => "very_next_page"},
               socket
             )
             |> fetch_patched_query_params!() == %{
               "table-id_order_by" => "actors:asc:name",
               "table-id_cursor" => "very_next_page",
               "table-id_filter[name]" => "buz"
             }
    end
  end

  describe "handle_live_table_event/3 for filtering" do
    setup do
      subject = subject_fixture()

      socket =
        %Phoenix.LiveView.Socket{
          assigns: %{subject: subject, __changed__: %{}}
        }
        |> put_uri_assigns(
          "/actors?table-id_cursor=next_page" <>
            "&table-id_filter%5Bemail%5D=bar" <>
            "&table-id_filter%5Bname%5D=buz" <>
            "&table-id_order_by=actors%3Aasc%3Aname"
        )
        |> assign_live_table("table-id",
          query_module: Actor.Query,
          sortable_fields: [
            {:actors, :name}
          ],
          callback: fn socket, list_opts ->
            {:ok, %{socket | private: %{list_opts: list_opts}}}
          end
        )

      %{socket: socket}
    end

    test "resets the query parameters with filter value is set to all", %{socket: socket} do
      assert handle_live_table_event(
               "filter",
               %{"table_id" => "table-id", "_target" => ["_reset:table-id", "name"]},
               socket
             )
             |> fetch_patched_query_params!() == %{
               "table-id_filter[email]" => "bar",
               "table-id_order_by" => "actors:asc:name"
             }
    end

    test "updates query parameters with new filter and resets the cursor", %{socket: socket} do
      assert handle_live_table_event(
               "filter",
               %{"table_id" => "table-id", "table-id" => %{"name" => "foo"}},
               socket
             )
             |> fetch_patched_query_params!() == %{
               "table-id_filter[email]" => "bar",
               "table-id_filter[name]" => "foo",
               "table-id_order_by" => "actors:asc:name"
             }
    end
  end

  describe "handle_live_table_event/3 for ordering" do
    setup do
      subject = subject_fixture()

      socket =
        %Phoenix.LiveView.Socket{
          assigns: %{subject: subject, __changed__: %{}}
        }
        |> put_uri_assigns(
          "/actors?table-id_cursor=next_page&table-id_filter%5Bname%5D=bar&table-id_order_by=actors%3Aasc%3Aname"
        )
        |> assign_live_table("table-id",
          query_module: Actor.Query,
          sortable_fields: [
            {:actors, :name}
          ],
          callback: fn socket, list_opts ->
            {:ok, %{socket | private: %{list_opts: list_opts}}}
          end
        )

      %{socket: socket}
    end

    test "updates query parameters with reverse order and resets the cursor", %{socket: socket} do
      assert handle_live_table_event(
               "order_by",
               %{"table_id" => "table-id", "order_by" => "actors:desc:name"},
               socket
             )
             |> fetch_patched_query_params!() == %{
               "table-id_filter[name]" => "bar",
               "table-id_order_by" => "actors:asc:name"
             }
    end
  end

  defp fetch_patched_query_params!(socket) do
    assert {:noreply, %{redirected: {:live, :patch, %{kind: :push, to: to}}}} = socket
    uri = URI.parse(to)
    URI.decode_query(uri.query)
  end
end

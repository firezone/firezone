defmodule PortalWeb.ResourcesCase do
  @moduledoc false

  defmacro __using__(_opts) do
    quote do
      use PortalWeb.ConnCase, async: true

      import Phoenix.LiveViewTest, except: [live: 2]

      # The table loads in an async task, so wait for it before returning.
      defp live(conn, path) do
        case Phoenix.LiveViewTest.live(conn, path) do
          {:ok, lv, _html} -> {:ok, lv, render_async(lv)}
          other -> other
        end
      end

      alias Portal.{Policy, Repo}
      alias Portal.Changes.Change
      alias Portal.Resource
      alias PortalWeb.Resources.Components.Database

      import Portal.AccountFixtures
      import Portal.DevicePostureFixtures
      import Portal.ActorFixtures
      import Portal.ClientSessionFixtures
      import Portal.DeviceFixtures
      import Portal.GroupFixtures
      import Portal.MembershipFixtures
      import Portal.PolicyAuthorizationFixtures
      import Portal.PolicyFixtures
      import Portal.SubjectFixtures
      import Portal.TokenFixtures
      import Portal.ResourceFixtures
      import Portal.SiteFixtures

      setup do
        account = account_fixture()
        actor = admin_actor_fixture(account: account)
        %{account: account, actor: actor}
      end

      import PortalWeb.ResourceTestHelpers
    end
  end
end

defmodule PortalWeb.ResourceTestHelpers do
  @moduledoc false
  import Phoenix.LiveViewTest
  alias Portal.Repo

  def set_last_seen_at(device, last_seen_at) do
    device
    |> Ecto.Changeset.change(last_seen_at: last_seen_at)
    |> Repo.update!()
  end

  def search_devices_in(lv, term) do
    lv
    |> element("input[name='device_search']")
    |> render_change(%{"device_search" => term})

    render_async(lv)
  end

  def click_and_await(lv, selector) do
    lv |> element(selector) |> render_click()
    render_async(lv)
  end

  def result_ids(lv) do
    lv
    |> render()
    |> Floki.parse_document!()
    |> Floki.find("button[phx-click='add_device']")
    |> Enum.flat_map(&Floki.attribute(&1, "phx-value-device_id"))
  end

  def result_count(lv) do
    lv
    |> render()
    |> Floki.parse_document!()
    |> Floki.find("button[phx-click='add_device']")
    |> length()
  end

  def count_occurrences(haystack, needle) do
    haystack
    |> :binary.matches(needle)
    |> length()
  end

  def site_select(html) do
    html |> Floki.parse_document!() |> Floki.find("#resource_site_id")
  end
end

defmodule Web.AnalyticsComponents do
  @moduledoc """
  The components that are responsible for embedding tracking codes into Firezone.
  """
  use Phoenix.Component
  alias Domain.Analytics

  def trackers(assigns) do
    assigns =
      assigns
      |> assign_new(:mixpanel_token, &Analytics.get_mixpanel_token/0)
      |> assign_new(:hubspot_workspace_id, &Analytics.get_hubspot_workspace_id/0)

    ~H"""
    <div id="analytics" class="hidden" phx-hook="Analytics">
      <.mixpanel_tracker token={@mixpanel_token} />
      <.hubspot_tracker hubspot_workspace_id={@hubspot_workspace_id} />
    </div>
    """
  end

  def hubspot_tracker(assigns) do
    ~H"""
    <script
      :if={not is_nil(@hubspot_workspace_id)}
      type="text/javascript"
      id="hs-script-loader"
      async
      defer
      src={"//js.hs-analytics.net/analytics/1716219600000/#{@hubspot_workspace_id}.js"}
    >
    </script>
    <script :if={not is_nil(@hubspot_workspace_id)} type="text/javascript">
      var _hsq = window._hsq = window._hsq || [];
      _hsq.push(["setPath", window.location.pathname + window.location.search]);
    </script>
    """
  end

  def mixpanel_tracker(assigns) do
    ~H"""
    <script :if={not is_nil(@token)} type="text/javascript">
      (function (f, b) { if (!b.__SV) { var e, g, i, h; window.mixpanel = b; b._i = []; b.init = function (e, f, c) { function g(a, d) { var b = d.split("."); 2 == b.length && ((a = a[b[0]]), (d = b[1])); a[d] = function () { a.push([d].concat(Array.prototype.slice.call(arguments, 0))); }; } var a = b; "undefined" !== typeof c ? (a = b[c] = []) : (c = "mixpanel"); a.people = a.people || []; a.toString = function (a) { var d = "mixpanel"; "mixpanel" !== c && (d += "." + c); a || (d += " (stub)"); return d; }; a.people.toString = function () { return a.toString(1) + ".people (stub)"; }; i = "disable time_event track track_pageview track_links track_forms track_with_groups add_group set_group remove_group register register_once alias unregister identify name_tag set_config reset opt_in_tracking opt_out_tracking has_opted_in_tracking has_opted_out_tracking clear_opt_in_out_tracking start_batch_senders people.set people.set_once people.unset people.increment people.append people.union people.track_charge people.clear_charges people.delete_user people.remove".split( " "); for (h = 0; h < i.length; h++) g(a, i[h]); var j = "set set_once union unset remove delete".split(" "); a.get_group = function () { function b(c) { d[c] = function () { call2_args = arguments; call2 = [c].concat(Array.prototype.slice.call(call2_args, 0)); a.push([e, call2]); }; } for ( var d = {}, e = ["get_group"].concat( Array.prototype.slice.call(arguments, 0)), c = 0; c < j.length; c++) b(j[c]); return d; }; b._i.push([e, f, c]); }; b.__SV = 1.2; e = f.createElement("script"); e.type = "text/javascript"; e.async = !0; e.src = "undefined" !== typeof MIXPANEL_CUSTOM_LIB_URL ? MIXPANEL_CUSTOM_LIB_URL : "file:" === f.location.protocol && "//cdn.mxpnl.com/libs/mixpanel-2-latest.min.js".match(/^\/\//) ? "https://cdn.mxpnl.com/libs/mixpanel-2-latest.min.js" : "//cdn.mxpnl.com/libs/mixpanel-2-latest.min.js"; g = f.getElementsByTagName("script")[0]; g.parentNode.insertBefore(e, g); } })(document, window.mixpanel || []);
    </script>
    <script :if={not is_nil(@token)} type="text/javascript">
      mixpanel.init("<%= @token %>", {track_pageview: "url-with-path-and-query-string"});
    </script>
    """
  end
end

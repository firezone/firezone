defmodule Portal.Repo.Migrations.DeviceMerge do
  @moduledoc """
  Merges device rows that describe one machine. A device is keyed by its
  `firezone_id`, or by the certificate it attested with, without an actor or
  a site in the key; rows that shared a key through different actors or
  sites are folded into the most recently seen one.

  Dry run from an IEx shell before running the manual migration:

      Code.require_file("priv/repo/migrations/helpers/device_merge.exs")
      Portal.Repo.Migrations.DeviceMerge.report()

  Each group keeps the row seen last (created last when never seen). The
  losers' actors, site assignments, policy authorizations, listed pool
  memberships and bound tokens move to the winner, and the losers are
  deleted. The losers' slugs stop resolving, which is what to announce.
  Groups mixing a client row and a gateway row are left alone and listed.
  """
  alias __MODULE__.Database

  @type group :: %{
          account_id: Ecto.UUID.t(),
          key: String.t(),
          winner: map(),
          losers: [map()],
          mixed_types?: boolean()
        }

  @doc "Every group of rows that describe one machine, winner first."
  @spec groups() :: [group()]
  def groups do
    Enum.map(Database.firezone_id_rows() ++ Database.certificate_rows(), &to_group/1)
  end

  @doc """
  Orders one key's rows into a group: the row seen last wins, falling back
  to the creation time for rows never seen, then to the id so the choice is
  stable. Rows mixing a client and a gateway are flagged rather than merged.
  """
  @spec to_group(%{account_id: Ecto.UUID.t(), key: String.t(), rows: [map()]}) :: group()
  def to_group(%{account_id: account_id, key: key, rows: rows}) do
    [winner | losers] =
      Enum.sort_by(rows, &{&1.seen_at, &1.id}, fn {a_seen, a_id}, {b_seen, b_id} ->
        case DateTime.compare(a_seen, b_seen) do
          :gt -> true
          :lt -> false
          :eq -> a_id <= b_id
        end
      end)

    %{
      account_id: account_id,
      key: key,
      winner: winner,
      losers: losers,
      mixed_types?: rows |> Enum.map(& &1.type) |> Enum.uniq() |> length() > 1
    }
  end

  @doc "Prints what `merge_all/0` would do without changing anything."
  def report do
    for group <- groups() do
      state = if group.mixed_types?, do: "SKIPPED (client and gateway rows)", else: "merge"

      IO.puts(
        "#{state} account=#{group.account_id} key=#{group.key} keep=#{group.winner.slug} " <>
          "drop=#{Enum.map_join(group.losers, ",", & &1.slug)}"
      )
    end

    :ok
  end

  @doc "Merges every group that can be merged; returns the merged and skipped groups."
  @spec merge_all() :: %{merged: [group()], skipped: [group()]}
  def merge_all do
    {skipped, mergeable} = Enum.split_with(groups(), & &1.mixed_types?)

    for group <- mergeable, do: merge(group)

    %{merged: mergeable, skipped: skipped}
  end

  @doc "Folds the losers of one group into its winner."
  @spec merge(group()) :: :ok
  def merge(%{mixed_types?: true}), do: :ok

  def merge(%{account_id: account_id, winner: winner, losers: losers}) do
    loser_ids = Enum.map(losers, & &1.id)

    {:ok, :merged} =
      Database.transact(fn ->
        Database.move_device_actors(account_id, winner.id, loser_ids)
        Database.move_site_devices(account_id, winner.id, loser_ids)
        Database.move_policy_authorizations(account_id, winner.id, loser_ids)
        Database.move_pool_memberships(account_id, winner.id, loser_ids)
        Database.move_bound_tokens(account_id, winner.id, loser_ids)
        Database.delete_devices(account_id, loser_ids)
        {:ok, :merged}
      end)

    :ok
  end

  defmodule Database do
    @moduledoc false
    alias Portal.Repo

    def transact(fun), do: Repo.transact(fun)

    @row_columns """
    jsonb_build_object(
      'id', id, 'slug', slug, 'type', type,
      'seen_at', COALESCE(last_seen_at, inserted_at)
    )
    """

    def firezone_id_rows do
      """
      SELECT account_id, firezone_id, jsonb_agg(#{@row_columns}) AS rows
      FROM devices
      WHERE firezone_id IS NOT NULL
      GROUP BY account_id, firezone_id
      HAVING count(*) > 1
      ORDER BY account_id, firezone_id
      """
      |> query_rows()
    end

    def certificate_rows do
      """
      SELECT account_id,
             encode(last_attested_cert_issuer, 'hex') || ':' || last_attested_cert_serial,
             jsonb_agg(#{@row_columns}) AS rows
      FROM devices
      WHERE last_attested_cert_issuer IS NOT NULL AND last_attested_cert_serial IS NOT NULL
      GROUP BY account_id, last_attested_cert_issuer, last_attested_cert_serial
      HAVING count(*) > 1
      ORDER BY 1, 2
      """
      |> query_rows()
    end

    defp query_rows(sql) do
      for [account_id, key, rows] <- Repo.query!(sql).rows do
        %{
          account_id: Ecto.UUID.load!(account_id),
          key: key,
          rows:
            for row <- rows do
              {:ok, seen_at, _offset} = DateTime.from_iso8601(row["seen_at"])
              %{id: row["id"], slug: row["slug"], type: row["type"], seen_at: seen_at}
            end
        }
      end
    end

    def move_device_actors(account_id, winner_id, loser_ids) do
      query!(
        """
        INSERT INTO device_actors (account_id, device_id, actor_id, first_seen_at, last_seen_at)
        SELECT account_id, $2, actor_id, min(first_seen_at), max(last_seen_at)
        FROM device_actors
        WHERE account_id = $1 AND device_id = ANY($3)
        GROUP BY account_id, actor_id
        ON CONFLICT (account_id, device_id, actor_id) DO UPDATE SET
          first_seen_at = LEAST(device_actors.first_seen_at, EXCLUDED.first_seen_at),
          last_seen_at = GREATEST(device_actors.last_seen_at, EXCLUDED.last_seen_at)
        """,
        [account_id, winner_id, loser_ids]
      )
    end

    def move_site_devices(account_id, winner_id, loser_ids) do
      query!(
        """
        INSERT INTO site_devices (account_id, site_id, device_id, inserted_at)
        SELECT account_id, site_id, $2, min(inserted_at)
        FROM site_devices
        WHERE account_id = $1 AND device_id = ANY($3)
        GROUP BY account_id, site_id
        ON CONFLICT (account_id, site_id, device_id) DO NOTHING
        """,
        [account_id, winner_id, loser_ids]
      )

      # A gateway's site column names one of its sites: a winner without one
      # takes the first loser's.
      query!(
        """
        UPDATE devices w SET site_id = l.site_id
        FROM (
          SELECT site_id FROM devices
          WHERE account_id = $1 AND id = ANY($3) AND site_id IS NOT NULL
          ORDER BY COALESCE(last_seen_at, inserted_at) DESC LIMIT 1
        ) l
        WHERE w.account_id = $1 AND w.id = $2 AND w.site_id IS NULL
        """,
        [account_id, winner_id, loser_ids]
      )
    end

    def move_policy_authorizations(account_id, winner_id, loser_ids) do
      for column <- ~w[initiating_device_id receiving_device_id] do
        query!(
          """
          UPDATE policy_authorizations SET #{column} = $2
          WHERE account_id = $1 AND #{column} = ANY($3)
          """,
          [account_id, winner_id, loser_ids]
        )
      end
    end

    # Listed pools name their devices in a jsonb array of ids: every loser id
    # becomes the winner's, once, with the list kept sorted and unique as the
    # criteria parser expects.
    def move_pool_memberships(account_id, winner_id, loser_ids) do
      # The ids are compared as the text the json holds, so they stay strings.
      Repo.query!(
        """
        UPDATE resources r SET device_membership_criteria = jsonb_set(
          r.device_membership_criteria,
          '{device,value}',
          (
            SELECT COALESCE(jsonb_agg(DISTINCT v ORDER BY v), '[]'::jsonb)
            FROM (
              SELECT CASE WHEN e = ANY($3) THEN $2 ELSE e END AS v
              FROM jsonb_array_elements_text(r.device_membership_criteria #> '{device,value}') AS e
            ) ids
          )
        )
        WHERE r.account_id = $1 AND r.type = 'device_pool'
          AND (r.device_membership_criteria #> '{device,value}') ?| $3
        """,
        [Ecto.UUID.dump!(account_id), winner_id, loser_ids]
      )
    end

    # A token bound to a loser follows the machine when the winner has none
    # of its own; otherwise it goes with the loser.
    def move_bound_tokens(account_id, winner_id, loser_ids) do
      query!(
        """
        UPDATE client_tokens t SET device_id = $2
        WHERE t.account_id = $1 AND t.device_id = ANY($3) AND t.rotated_at IS NULL
          AND NOT EXISTS (
            SELECT 1 FROM client_tokens w
            WHERE w.account_id = $1 AND w.device_id = $2
          )
          AND t.id = (
            SELECT id FROM client_tokens c
            WHERE c.account_id = $1 AND c.device_id = ANY($3) AND c.rotated_at IS NULL
            ORDER BY c.inserted_at DESC LIMIT 1
          )
        """,
        [account_id, winner_id, loser_ids]
      )
    end

    def delete_devices(account_id, loser_ids) do
      query!("DELETE FROM devices WHERE account_id = $1 AND id = ANY($2)", [account_id, loser_ids])
    end

    defp query!(sql, params) do
      params = Enum.map(params, &dump/1)
      Repo.query!(sql, params)
    end

    defp dump(ids) when is_list(ids), do: Enum.map(ids, &dump/1)

    defp dump(value) when is_binary(value) do
      case Ecto.UUID.dump(value) do
        {:ok, bytes} -> bytes
        :error -> value
      end
    end

    defp dump(value), do: value
  end
end

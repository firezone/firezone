defmodule Domain.Directories.Okta.SyncState.Changeset do
  use Domain, :changeset
  alias Domain.Directories.Okta.SyncState
  import Ecto.Changeset

  @sync_pairs [
    {:full_user_sync_started_at, :full_user_sync_finished_at},
    {:full_group_sync_started_at, :full_group_sync_finished_at},
    {:full_member_sync_started_at, :full_member_sync_finished_at},
    {:delta_user_sync_started_at, :delta_user_sync_finished_at},
    {:delta_group_sync_started_at, :delta_group_sync_finished_at},
    {:delta_member_sync_started_at, :delta_member_sync_finished_at}
  ]

  @fields Enum.flat_map(@sync_pairs, fn {start, finish} -> [start, finish] end)

  def changeset(%SyncState{} = sync_state, attrs) do
    sync_state
    |> cast(attrs, @fields)
    |> validate_sync_start_and_finish_times()
  end

  # Validates start and finish times for sync operations.
  # - If `started_at` is set, `finished_at` is forced to `nil`.
  # - If `finished_at` is set, it must be after a non-nil `started_at`.
  defp validate_sync_start_and_finish_times(changeset) do
    Enum.reduce(@sync_pairs, changeset, fn {started_at_field, finished_at_field}, acc_changeset ->
      case get_change(acc_changeset, started_at_field) do
        # Rule 1: Starting a sync clears the finish time
        new_started_at when not is_nil(new_started_at) ->
          put_change(acc_changeset, finished_at_field, nil)

        # Rule 1 doesn't apply, check Rule 2
        _ ->
          case get_change(acc_changeset, finished_at_field) do
            new_finished_at when not is_nil(new_finished_at) ->
              # Rule 2: Finishing a sync requires started_at and correct order
              current_started_at = get_field(acc_changeset, started_at_field)

              cond do
                is_nil(current_started_at) ->
                  add_error(
                    acc_changeset,
                    finished_at_field,
                    "cannot be set when #{started_at_field} is nil"
                  )

                DateTime.compare(new_finished_at, current_started_at) != :gt ->
                  add_error(acc_changeset, finished_at_field, "must be after #{started_at_field}")

                true ->
                  # Valid finish time
                  acc_changeset
              end

            # finished_at not changing or being set to nil
            _ ->
              acc_changeset
          end
      end
    end)
  end
end

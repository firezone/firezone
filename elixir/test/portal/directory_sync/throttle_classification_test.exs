defmodule Portal.DirectorySync.ThrottleClassificationTest do
  use Portal.DataCase, async: true

  import Portal.EntraDirectoryFixtures
  import Portal.GoogleDirectoryFixtures
  import Portal.OktaDirectoryFixtures

  @throttled [408, 429]

  describe "Entra" do
    test "keeps the directory enabled when the provider throttles" do
      for status <- @throttled do
        directory = entra_directory_fixture()

        Portal.Entra.ErrorHandler.handle(
          Portal.Entra.SyncError.exception(
            directory_id: directory.id,
            step: :list_users,
            error: %Req.Response{status: status, body: ""}
          ),
          directory.id
        )

        directory = Repo.get!(Portal.Entra.Directory, directory.id)
        refute directory.is_disabled
        assert directory.errored_at
      end
    end

    test "keeps the directory enabled when a throttled batch fails" do
      for tag <- [:batch_all_failed, :batch_request_failed], status <- @throttled do
        directory = entra_directory_fixture()

        Portal.Entra.ErrorHandler.handle(
          Portal.Entra.SyncError.exception(
            directory_id: directory.id,
            step: :list_users,
            error: {tag, status, ""}
          ),
          directory.id
        )

        directory = Repo.get!(Portal.Entra.Directory, directory.id)
        refute directory.is_disabled
      end
    end

    test "still disables the directory when access is denied" do
      directory = entra_directory_fixture()

      Portal.Entra.ErrorHandler.handle(
        Portal.Entra.SyncError.exception(
          directory_id: directory.id,
          step: :list_users,
          error: %Req.Response{status: 403, body: ""}
        ),
        directory.id
      )

      assert Repo.get!(Portal.Entra.Directory, directory.id).is_disabled
    end
  end

  describe "Google" do
    test "keeps the directory enabled when the provider throttles" do
      for status <- @throttled do
        directory = google_directory_fixture()

        Portal.Google.ErrorHandler.handle(
          Portal.Google.SyncError.exception(
            directory_id: directory.id,
            step: :list_users,
            error: %Req.Response{status: status, body: ""}
          ),
          directory.id
        )

        directory = Repo.get!(Portal.Google.Directory, directory.id)
        refute directory.is_disabled
        assert directory.errored_at
      end
    end

    test "still disables the directory when access is denied" do
      directory = google_directory_fixture()

      Portal.Google.ErrorHandler.handle(
        Portal.Google.SyncError.exception(
          directory_id: directory.id,
          step: :list_users,
          error: %Req.Response{status: 403, body: ""}
        ),
        directory.id
      )

      assert Repo.get!(Portal.Google.Directory, directory.id).is_disabled
    end
  end

  describe "Okta" do
    test "keeps the directory enabled when the provider throttles" do
      for status <- @throttled do
        directory = okta_directory_fixture()

        Portal.Okta.ErrorHandler.handle(
          Portal.Okta.SyncError.exception(
            directory_id: directory.id,
            step: :list_users,
            error: %Req.Response{status: status, body: ""}
          ),
          directory.id
        )

        directory = Repo.get!(Portal.Okta.Directory, directory.id)
        refute directory.is_disabled
        assert directory.errored_at
      end
    end

    test "still disables the directory when access is denied" do
      directory = okta_directory_fixture()

      Portal.Okta.ErrorHandler.handle(
        Portal.Okta.SyncError.exception(
          directory_id: directory.id,
          step: :list_users,
          error: %Req.Response{status: 403, body: ""}
        ),
        directory.id
      )

      assert Repo.get!(Portal.Okta.Directory, directory.id).is_disabled
    end
  end
end

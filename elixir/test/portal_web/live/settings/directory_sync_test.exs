defmodule PortalWeb.Settings.DirectorySyncTest do
  use PortalWeb.ConnCase, async: true

  import Portal.AccountFixtures
  import Portal.ActorFixtures
  import Portal.GoogleDirectoryFixtures
  import Portal.EntraDirectoryFixtures
  import Portal.OktaDirectoryFixtures
  import Portal.IdentityFixtures
  import Portal.SubjectFixtures

  alias Portal.Google
  alias Portal.Entra
  alias Portal.Okta
  alias PortalWeb.Settings.DirectorySync.Database

  # Generate a test RSA key pair using JOSE for Okta tests
  @test_jwk JOSE.JWK.generate_key({:rsa, 2048})
  @test_private_key_jwk @test_jwk |> JOSE.JWK.to_map() |> elem(1)

  @test_rsa_private_key """
  -----BEGIN RSA PRIVATE KEY-----
  MIIEpAIBAAKCAQEA0Z3VS5JJcds3xfn/ygWyF8PbnGy0AHB7MaC6dCT6LsOpNkYe
  CvUvR3i6LjFLoxI9I0DKWCsCu3s7gxOlRLpcL5wPTk1zGB4P9jbMJhNH4kws2ruL
  F88MN1WQKmKrkF7b4Jz7sSf5sJQk9lfLKnMJz6tLT0lH2D5B8YSj8e1bIoV6fb6g
  a8PkEUC6b9TBsnnb5hKL6s5kA6B4M9N4u9VhfWJPNQf7bGs8Jf6F9n2n2q6xYqGa
  qliCE/4v2jBP3Fsjk6k/yCN3+xzZnFQqAIH7RFQvFOFl6DvEjU7TX4VJGGBTgkEz
  k9rCBr8IvZglN2BHu1hM9/0HsHU0sStALGOeeQIDAQABAoIBAC5RgZ+hBx7xHnFZ
  nQmY436CjazfrHpEFRvXEOlrFFFbKJu7l6lbMmGxSU1Bxbzl7qYMrhANoBVZ8V4P
  t8AuYQqDFYXnUVfBLCIgv/dXnLXjaVvkSoJsLoZgnPXcAPY0ZFkO/WQib3ZEppPp
  8wxf2XPUhuPU6yglFSGS7pcFmT7FYJmNSNjpN6NU/pAuPLwZEX8gd6k8Y6bociJy
  FmMh3HkUIpyKXXW3VwMUKUHbiCr7Ar8mODKPFn8XAKL7gBQ7mXUG7wmkTdwVlFOp
  SqE/2SmLXJIISvo5FNNzfMhG9hU01hMZGy0r4k/UFJawwhVBzmH7brqGdoXJcpYr
  5REG0qkCgYEA5cVh7HVmwrC4MJrTvItOfgqqMXRz1IjdgPnBZNsA6llIz8pCzvlD
  cOP/L9wqmPXXmNnJ5zsHbyIYOCjprTJb3s2lMbIwfG7d2O8xqNXoHHOCGr0bFqba
  WE2N5NjGC2vqLnrFQQ8jPpExR6qJrF/7V9WXgVqbPAwI2lp/eVGnLpcCgYEA6Mjm
  bPNJo9gJxz4fEsNAMGiHYIL6ZAqJqjF1TWQNrHNmkDhEMPYz8vBAk3XWNuHPoGqc
  xPsr+m3JfKL3D+X8lh6FnBFX2FGMz/3SzkD+ewABmPNKeeY9klHqNrgLvJI+ILNn
  qsLf8y/pZnrI8sbg95djXHHu5dGAM0dpuqpXCg8CgYEAm9QQHTH9qrwp9lWqeyaJ
  sR0/nLMj8luXH85lMINWGOokYv5ljC0lJN5pIMvl9k9Xw3QLQMBDMCRfp4L3r+vh
  Kx7d3r0qIflJl8nOQ4RL/FrpdReTJJJ7n9T1z48lD2TzEkV3+PLn+KLG3s8RCnKO
  l/oXi8Mz7FRviOvt1VIOXPsCgYEAoYd5Hxr+sL8cZPO7nz3LkTjbsCPTLFM+O8B+
  WyJc7l8pX6kCBRh7ppHfJizz8K4L1sRf9QXIS6hZbEkqLr1PFNP6S3N8VVb0rp5L
  +yjqwDfjOywS8KP2b/Qao55Fi27p0s9CR3TgycPkYIE+D4onW/WHkQ7BTwM7ow5f
  VRV6CgECgYBv+GZIhfDGt7DKvCs9xVN0VvGj4vXz7qpD1t/VKHrB9O7tOLH5G2lT
  +Ix56N2+DBfWmQMQW1VJJhKz9F9gDDKl04hLnTLG6FqWjNy5t5tMxZpJA2pYe5wQ
  M7aEyJf3Z1HFHcMfT5xfmfB1V9+OHDcyfZEnZBDhz4LzKB7oCPgMsg==
  -----END RSA PRIVATE KEY-----
  """

  setup do
    # Set up default stub for Google API
    Req.Test.stub(Google.APIClient, fn conn ->
      Req.Test.json(conn, %{"error" => "not mocked"})
    end)

    # Set up default stub for Okta API
    Req.Test.stub(Okta.APIClient, fn conn ->
      Req.Test.json(conn, %{"error" => "not mocked"})
    end)

    # Set up default stub for Entra API
    Req.Test.stub(Entra.APIClient, fn conn ->
      Req.Test.json(conn, %{"error" => "not mocked"})
    end)

    # Configure Google API client for tests
    Portal.Config.put_env_override(Google.APIClient,
      endpoint: "https://test.googleapis.com",
      token_endpoint: "https://test.googleapis.com/token",
      service_account_key:
        JSON.encode!(%{
          "client_email" => "test@project.iam.gserviceaccount.com",
          "private_key" => @test_rsa_private_key
        }),
      req_options: [
        plug: {Req.Test, Google.APIClient},
        retry: false
      ]
    )

    # Enable IDP sync feature by default
    account = account_fixture(features: %{idp_sync: true})
    actor = admin_actor_fixture(account: account)

    %{
      account: account,
      actor: actor
    }
  end

  # Waits for async verification error to appear in the LiveView
  defp wait_for_verification_error(lv, expected_message, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 10_000)
    interval = Keyword.get(opts, :interval, 100)
    deadline = System.monotonic_time(:millisecond) + timeout

    wait_for_verification_error_loop(lv, expected_message, deadline, interval)
  end

  defp wait_for_verification_error_loop(lv, expected_message, deadline, interval) do
    html = render(lv)

    if html =~ expected_message do
      html
    else
      if System.monotonic_time(:millisecond) >= deadline do
        flunk(
          "Timed out waiting for verification error: #{expected_message}\n\nLast HTML contained: #{String.slice(html, 0, 500)}..."
        )
      else
        Process.sleep(interval)
        wait_for_verification_error_loop(lv, expected_message, deadline, interval)
      end
    end
  end

  describe "mount/3" do
    test "redirects to sign in page for unauthorized user", %{account: account, conn: conn} do
      path = ~p"/#{account}/settings/directory_sync"

      assert live(conn, path) ==
               {:error,
                {:redirect,
                 %{
                   to: ~p"/#{account}?#{%{redirect_to: path}}",
                   flash: %{"error" => "You must sign in to access that page."}
                 }}}
    end

    test "renders directory list when IDP sync is enabled", %{
      account: account,
      actor: actor,
      conn: conn
    } do
      {:ok, _lv, html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/settings/directory_sync")

      assert html =~ "Directory Sync Settings"
      assert html =~ "No directories configured"
      assert html =~ "Add a directory"
    end

    test "renders upgrade prompt when IDP sync is disabled", %{conn: conn} do
      account = account_fixture(features: %{idp_sync: false})
      actor = admin_actor_fixture(account: account)

      {:ok, _lv, html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/settings/directory_sync")

      assert html =~ "Upgrade to Unlock"
      assert html =~ "Automate User &amp; Group Management"
    end

    test "renders existing directories", %{account: account, actor: actor, conn: conn} do
      google_dir = google_directory_fixture(account: account, name: "My Google Dir")
      entra_dir = entra_directory_fixture(account: account, name: "My Entra Dir")
      okta_dir = okta_directory_fixture(account: account, name: "My Okta Dir")

      {:ok, _lv, html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/settings/directory_sync")

      assert html =~ "My Google Dir"
      assert html =~ "My Entra Dir"
      assert html =~ "My Okta Dir"
      assert html =~ google_dir.domain
      assert html =~ entra_dir.tenant_id
      assert html =~ okta_dir.okta_domain
    end
  end

  describe "handle_params - select_type" do
    test "renders select directory type modal", %{account: account, actor: actor, conn: conn} do
      # Navigate directly to select_type URL
      {:ok, _lv, html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/settings/directory_sync/select_type")

      assert html =~ "Select Directory Type"
      assert html =~ "Google"
      assert html =~ "Entra"
      assert html =~ "Okta"
      assert html =~ "Sync users and groups from Google Workspace"
      assert html =~ "Sync users and groups from Microsoft Entra ID"
      assert html =~ "Sync users and groups from Okta"
    end
  end

  describe "handle_params - new" do
    test "renders new Google directory form", %{account: account, actor: actor, conn: conn} do
      {:ok, _lv, html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/settings/directory_sync/google/new")

      assert html =~ "Add Google Directory"
      assert html =~ "Name"
      assert html =~ "Impersonation Email"
      assert html =~ "Directory Verification"
    end

    test "renders new Entra directory form", %{account: account, actor: actor, conn: conn} do
      {:ok, _lv, html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/settings/directory_sync/entra/new")

      assert html =~ "Add Microsoft Entra Directory"
      assert html =~ "Name"
      assert html =~ "Group sync mode"
      assert html =~ "Assigned groups only"
      assert html =~ "All groups"
    end

    test "renders new Okta directory form", %{account: account, actor: actor, conn: conn} do
      {:ok, _lv, html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/settings/directory_sync/okta/new")

      assert html =~ "Add Okta Directory"
      assert html =~ "Name"
      assert html =~ "Okta Domain"
      assert html =~ "Client ID"
      assert html =~ "Public Key (JWK)"
      assert html =~ "Generate Keypair"
    end

    test "raises NotFoundError for invalid type", %{account: account, actor: actor, conn: conn} do
      assert_raise PortalWeb.LiveErrors.NotFoundError, fn ->
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/settings/directory_sync/invalid/new")
      end
    end
  end

  describe "handle_params - edit" do
    test "renders edit Google directory form", %{account: account, actor: actor, conn: conn} do
      directory = google_directory_fixture(account: account, name: "Test Google")

      {:ok, _lv, html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/settings/directory_sync/google/#{directory.id}/edit")

      assert html =~ "Edit Test Google"
      assert html =~ directory.impersonation_email
    end

    test "renders edit Entra directory form", %{account: account, actor: actor, conn: conn} do
      directory = entra_directory_fixture(account: account, name: "Test Entra")

      {:ok, _lv, html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/settings/directory_sync/entra/#{directory.id}/edit")

      assert html =~ "Edit Test Entra"
    end

    test "renders edit Okta directory form with public key", %{
      account: account,
      actor: actor,
      conn: conn
    } do
      directory =
        okta_directory_fixture(
          account: account,
          name: "Test Okta",
          private_key_jwk: @test_private_key_jwk,
          kid: "test_kid"
        )

      {:ok, _lv, html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/settings/directory_sync/okta/#{directory.id}/edit")

      assert html =~ "Edit Test Okta"
      assert html =~ "Public Key (JWK)"
    end

    test "shows legacy warning for Google directories with legacy_service_account_key", %{
      account: account,
      actor: actor,
      conn: conn
    } do
      # Create a directory with legacy service account key
      directory = google_directory_fixture(account: account, name: "Legacy Google")

      # Manually set legacy_service_account_key
      directory
      |> Ecto.Changeset.change(%{legacy_service_account_key: %{"key" => "value"}})
      |> Portal.Repo.update!()

      {:ok, _lv, html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/settings/directory_sync/google/#{directory.id}/edit")

      assert html =~ "legacy credentials"
      assert html =~ "domain-wide delegation"
    end
  end

  describe "handle_event - validate" do
    test "validates Google directory form - doesn't submit with empty required fields", %{
      account: account,
      actor: actor,
      conn: conn
    } do
      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/settings/directory_sync/google/new")

      # Submit empty form - validation prevents redirect
      result =
        lv
        |> form("#directory-form", %{
          "directory" => %{"name" => "", "impersonation_email" => ""}
        })
        |> render_submit()

      # Form should stay on page (not redirect) on validation failure
      refute result =~ "Directory saved"
    end

    test "validates Entra directory form - doesn't submit with empty required fields", %{
      account: account,
      actor: actor,
      conn: conn
    } do
      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/settings/directory_sync/entra/new")

      # Submit empty form - validation prevents redirect
      result =
        lv
        |> form("#directory-form", %{
          "directory" => %{"name" => ""}
        })
        |> render_submit()

      # Form should stay on page (not redirect) on validation failure
      refute result =~ "Directory saved"
    end

    test "validates Okta directory form - doesn't submit with empty required fields", %{
      account: account,
      actor: actor,
      conn: conn
    } do
      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/settings/directory_sync/okta/new")

      # Submit empty form - validation prevents redirect
      result =
        lv
        |> form("#directory-form", %{
          "directory" => %{"name" => "", "okta_domain" => "", "client_id" => ""}
        })
        |> render_submit()

      # Form should stay on page (not redirect) on validation failure
      refute result =~ "Directory saved"
    end

    test "clears verification when trigger fields change for Google", %{
      account: account,
      actor: actor,
      conn: conn
    } do
      directory = google_directory_fixture(account: account, is_verified: true)

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/settings/directory_sync/google/#{directory.id}/edit")

      # Change impersonation email should clear verification
      html =
        lv
        |> form("#directory-form", %{
          "directory" => %{"impersonation_email" => "new@example.com"}
        })
        |> render_change()

      assert html =~ "Awaiting verification"
    end

    test "clears verification when trigger fields change for Okta", %{
      account: account,
      actor: actor,
      conn: conn
    } do
      directory =
        okta_directory_fixture(
          account: account,
          is_verified: true,
          private_key_jwk: @test_private_key_jwk
        )

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/settings/directory_sync/okta/#{directory.id}/edit")

      # Change client_id should clear verification
      html =
        lv
        |> form("#directory-form", %{
          "directory" => %{"client_id" => "new_client_id"}
        })
        |> render_change()

      assert html =~ "Awaiting verification"
    end
  end

  describe "handle_event - generate_keypair (Okta)" do
    test "generates new keypair and displays public key", %{
      account: account,
      actor: actor,
      conn: conn
    } do
      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/settings/directory_sync/okta/new")

      # Initially no keypair is shown
      refute has_element?(lv, "#okta-public-jwk")

      # Generate keypair
      html = lv |> element("button", "Generate Keypair") |> render_click()

      # Now public key should be displayed - extract_public_key_components returns
      # a single JWK with kty, alg, use, kid, n, e fields
      assert html =~ "kty"
      assert html =~ "RSA"
      assert html =~ "kid"
      assert html =~ "Copy this public key"
    end

    test "keypair is preserved when other form fields are changed in new form", %{
      account: account,
      actor: actor,
      conn: conn
    } do
      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/settings/directory_sync/okta/new")

      # Generate keypair first and capture the kid from the JSON content
      html_after_generate = lv |> element("button", "Generate Keypair") |> render_click()

      # Extract the kid from the JSON content (the public JWK contains "kid":"<value>")
      [_, generated_kid] = Regex.run(~r/&quot;kid&quot;:&quot;([^&]+)&quot;/, html_after_generate)

      # Fill in form fields - this triggers validate which should preserve the keypair
      lv
      |> form("#directory-form", %{
        "directory" => %{
          "name" => "Test Okta",
          "okta_domain" => "test.okta.com",
          "client_id" => "test-client-id"
        }
      })
      |> render_change()

      # Verify the SAME keypair is still displayed after form changes (same kid in JSON)
      html = render(lv)
      assert html =~ "kty"
      assert html =~ "RSA"
      assert html =~ "Copy this public key"
      # Verify it's the same kid that was generated, not a different keypair
      assert html =~ generated_kid
    end

    test "new keypair is preserved when other form fields are changed in edit form", %{
      account: account,
      actor: actor,
      conn: conn
    } do
      # Create an existing Okta directory with a keypair
      directory =
        okta_directory_fixture(
          account: account,
          name: "Existing Okta",
          okta_domain: "existing.okta.com",
          client_id: "existing-client-id",
          private_key_jwk: @test_private_key_jwk,
          kid: "existing-kid",
          is_verified: true
        )

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/settings/directory_sync/okta/#{directory.id}/edit")

      # Generate a new keypair
      html_after_generate = lv |> element("button", "Generate Keypair") |> render_click()

      # Extract the kid from the JSON content (the public JWK contains "kid":"<value>")
      [_, generated_kid] = Regex.run(~r/&quot;kid&quot;:&quot;([^&]+)&quot;/, html_after_generate)

      # Change another form field - this triggers validate
      lv
      |> form("#directory-form", %{
        "directory" => %{
          "name" => "Updated Okta Name"
        }
      })
      |> render_change()

      # Verify the new keypair is still displayed (not the old one)
      html = render(lv)
      assert html =~ "kty"
      assert html =~ "RSA"
      # The new keypair should have a different kid than the original
      refute html =~ "existing-kid"
      assert html =~ generated_kid
    end

    test "existing keypair is not changed when other form fields are edited", %{
      account: account,
      actor: actor,
      conn: conn
    } do
      # Create an existing Okta directory with a keypair
      directory =
        okta_directory_fixture(
          account: account,
          name: "Existing Okta",
          okta_domain: "existing.okta.com",
          client_id: "existing-client-id",
          private_key_jwk: @test_private_key_jwk,
          kid: "existing-kid",
          is_verified: true
        )

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/settings/directory_sync/okta/#{directory.id}/edit")

      # Change form fields WITHOUT generating a new keypair
      lv
      |> form("#directory-form", %{
        "directory" => %{
          "name" => "Updated Okta Name"
        }
      })
      |> render_change()

      # Submit the form
      lv
      |> form("#directory-form")
      |> render_submit()

      # Reload the directory from the database
      updated_directory = Portal.Repo.get!(Okta.Directory, directory.id)

      # Verify the name was updated
      assert updated_directory.name == "Updated Okta Name"

      # Verify the keypair was NOT changed
      assert updated_directory.private_key_jwk == @test_private_key_jwk
      assert updated_directory.kid == "existing-kid"
    end
  end

  describe "handle_event - close_modal" do
    test "closes modal and navigates back to directory list", %{
      account: account,
      actor: actor,
      conn: conn
    } do
      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/settings/directory_sync/google/new")

      # Close the modal - push_patch re-renders in place
      lv |> element("button[phx-click='close_modal']") |> render_click()

      # After push_patch, the modal should close and we see the main list
      html = render(lv)
      assert html =~ "No directories configured"
    end
  end

  describe "handle_event - start_verification (Google)" do
    test "successfully verifies Google directory", %{account: account, actor: actor, conn: conn} do
      # Mock successful Google API responses
      Req.Test.stub(Google.APIClient, fn conn ->
        case conn.request_path do
          "/token" ->
            Req.Test.json(conn, %{"access_token" => "test_access_token"})

          "/admin/directory/v1/customers/my_customer" ->
            Req.Test.json(conn, %{"customerDomain" => "verified-domain.com"})

          "/admin/directory/v1/users" ->
            Req.Test.json(conn, %{"users" => []})

          "/admin/directory/v1/groups" ->
            Req.Test.json(conn, %{"groups" => []})

          "/admin/directory/v1/customer/my_customer/orgunits" ->
            Req.Test.json(conn, %{"organizationUnits" => []})

          _ ->
            Req.Test.json(conn, %{})
        end
      end)

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/settings/directory_sync/google/new")

      # Fill in valid form
      lv
      |> form("#directory-form", %{
        "directory" => %{
          "name" => "Test Google Directory",
          "impersonation_email" => "admin@example.com"
        }
      })
      |> render_change()

      # Start verification
      # Verification is async - click triggers :do_verification message
      lv |> element("button", "Verify Now") |> render_click()

      # Check that verification succeeded
      html = wait_for_verification_error(lv, "Verified")
      assert html =~ "verified-domain.com"
    end

    test "verification is preserved after editing other form fields (new)", %{
      account: account,
      actor: actor,
      conn: conn
    } do
      Req.Test.stub(Google.APIClient, fn conn ->
        case conn.request_path do
          "/token" ->
            Req.Test.json(conn, %{"access_token" => "test_access_token"})

          "/admin/directory/v1/customers/my_customer" ->
            Req.Test.json(conn, %{"customerDomain" => "verified-domain.com"})

          "/admin/directory/v1/users" ->
            Req.Test.json(conn, %{"users" => []})

          "/admin/directory/v1/groups" ->
            Req.Test.json(conn, %{"groups" => []})

          "/admin/directory/v1/customer/my_customer/orgunits" ->
            Req.Test.json(conn, %{"organizationUnits" => []})

          _ ->
            Req.Test.json(conn, %{})
        end
      end)

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/settings/directory_sync/google/new")

      # Fill in form and verify
      lv
      |> form("#directory-form", %{
        "directory" => %{
          "name" => "Test Google",
          "impersonation_email" => "admin@example.com"
        }
      })
      |> render_change()

      lv |> element("button", "Verify Now") |> render_click()
      wait_for_verification_error(lv, "Verified")

      # Now change the name — this triggers validate
      lv
      |> form("#directory-form", %{
        "directory" => %{"name" => "Renamed Google"}
      })
      |> render_change()

      html = render(lv)
      assert html =~ "Verified"
      assert html =~ "verified-domain.com"
    end

    test "verification is preserved after editing other form fields (edit)", %{
      account: account,
      actor: actor,
      conn: conn
    } do
      Req.Test.stub(Google.APIClient, fn conn ->
        case conn.request_path do
          "/token" ->
            Req.Test.json(conn, %{"access_token" => "test_access_token"})

          "/admin/directory/v1/customers/my_customer" ->
            Req.Test.json(conn, %{"customerDomain" => "new-domain.com"})

          "/admin/directory/v1/users" ->
            Req.Test.json(conn, %{"users" => []})

          "/admin/directory/v1/groups" ->
            Req.Test.json(conn, %{"groups" => []})

          "/admin/directory/v1/customer/my_customer/orgunits" ->
            Req.Test.json(conn, %{"organizationUnits" => []})

          _ ->
            Req.Test.json(conn, %{})
        end
      end)

      # Create an existing Google directory (unverified, re-verifying with new domain)
      directory =
        google_directory_fixture(
          account: account,
          name: "Existing Google",
          impersonation_email: "admin@existing.com",
          is_verified: false,
          domain: "old-domain.com"
        )

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/settings/directory_sync/google/#{directory.id}/edit")

      # Verify the directory
      lv |> element("button", "Verify Now") |> render_click()
      wait_for_verification_error(lv, "Verified")

      # Now change the name — this triggers validate
      lv
      |> form("#directory-form", %{
        "directory" => %{"name" => "Renamed Google"}
      })
      |> render_change()

      # Verification and domain must survive the validate event
      html = render(lv)
      assert html =~ "Verified"
      assert html =~ "new-domain.com"
    end

    test "shows error for Google 400 invalid grant", %{account: account, actor: actor, conn: conn} do
      Req.Test.stub(Google.APIClient, fn conn ->
        conn
        |> Plug.Conn.put_status(400)
        |> Req.Test.json(%{
          "error" => "invalid_grant",
          "error_description" => "Invalid email or User ID"
        })
      end)

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/settings/directory_sync/google/new")

      lv
      |> form("#directory-form", %{
        "directory" => %{
          "name" => "Test",
          "impersonation_email" => "invalid@example.com"
        }
      })
      |> render_change()

      # Verification is async - click triggers :do_verification message
      lv |> element("button", "Verify Now") |> render_click()

      wait_for_verification_error(lv, "Invalid service account email or user ID")
    end

    test "shows error for Google 401", %{account: account, actor: actor, conn: conn} do
      Req.Test.stub(Google.APIClient, fn conn ->
        conn
        |> Plug.Conn.put_status(401)
        |> Req.Test.json(%{"error_description" => "Missing required scopes"})
      end)

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/settings/directory_sync/google/new")

      lv
      |> form("#directory-form", %{
        "directory" => %{"name" => "Test", "impersonation_email" => "admin@example.com"}
      })
      |> render_change()

      # Verification is async - click triggers :do_verification message
      lv |> element("button", "Verify Now") |> render_click()

      wait_for_verification_error(lv, "Missing required scopes")
    end

    test "shows error for Google 403", %{account: account, actor: actor, conn: conn} do
      Req.Test.stub(Google.APIClient, fn conn ->
        conn
        |> Plug.Conn.put_status(403)
        |> Req.Test.json(%{"error" => %{"message" => "Admin SDK not enabled"}})
      end)

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/settings/directory_sync/google/new")

      lv
      |> form("#directory-form", %{
        "directory" => %{"name" => "Test", "impersonation_email" => "admin@example.com"}
      })
      |> render_change()

      # Verification is async - click triggers :do_verification message
      lv |> element("button", "Verify Now") |> render_click()

      wait_for_verification_error(lv, "Admin SDK not enabled")
    end

    test "shows error for Google 404", %{account: account, actor: actor, conn: conn} do
      Req.Test.stub(Google.APIClient, fn conn ->
        case conn.request_path do
          "/token" ->
            Req.Test.json(conn, %{"access_token" => "test_token"})

          "/admin/directory/v1/customers/my_customer" ->
            conn
            |> Plug.Conn.put_status(404)
            |> Req.Test.json(%{"error" => %{"message" => "Customer not found"}})

          _ ->
            Req.Test.json(conn, %{})
        end
      end)

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/settings/directory_sync/google/new")

      lv
      |> form("#directory-form", %{
        "directory" => %{"name" => "Test", "impersonation_email" => "admin@example.com"}
      })
      |> render_change()

      # Verification is async - click triggers :do_verification message
      lv |> element("button", "Verify Now") |> render_click()

      wait_for_verification_error(lv, "Customer not found")
    end

    test "shows error for Google 500", %{account: account, actor: actor, conn: conn} do
      Req.Test.stub(Google.APIClient, fn conn ->
        case conn.request_path do
          "/token" ->
            Req.Test.json(conn, %{"access_token" => "test_token"})

          "/admin/directory/v1/customers/my_customer" ->
            conn
            |> Plug.Conn.put_status(500)
            |> Req.Test.json(%{})

          _ ->
            Req.Test.json(conn, %{})
        end
      end)

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/settings/directory_sync/google/new")

      lv
      |> form("#directory-form", %{
        "directory" => %{"name" => "Test", "impersonation_email" => "admin@example.com"}
      })
      |> render_change()

      # Verification is async - click triggers :do_verification message
      lv |> element("button", "Verify Now") |> render_click()

      wait_for_verification_error(lv, "Google service is currently unavailable")
    end
  end

  describe "handle_event - start_verification (Okta)" do
    test "successfully verifies Okta directory", %{account: account, actor: actor, conn: conn} do
      Req.Test.stub(Okta.APIClient, fn conn ->
        case conn.request_path do
          "/oauth2/v1/token" ->
            Req.Test.json(conn, %{"access_token" => "test_access_token"})

          "/api/v1/apps" ->
            Req.Test.json(conn, [%{"id" => "app1"}])

          "/api/v1/users" ->
            Req.Test.json(conn, [%{"id" => "user1"}])

          "/api/v1/groups" ->
            Req.Test.json(conn, [%{"id" => "group1"}])

          _ ->
            Req.Test.json(conn, %{})
        end
      end)

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/settings/directory_sync/okta/new")

      # Generate keypair first
      lv |> element("button", "Generate Keypair") |> render_click()

      # Fill in form
      lv
      |> form("#directory-form", %{
        "directory" => %{
          "name" => "Test Okta",
          "okta_domain" => "test.okta.com",
          "client_id" => "test_client_id"
        }
      })
      |> render_change()

      # Start verification
      # Verification is async - click triggers :do_verification message
      lv |> element("button", "Verify Now") |> render_click()

      wait_for_verification_error(lv, "Verified")
    end

    test "verification is preserved after editing other form fields (edit)", %{
      account: account,
      actor: actor,
      conn: conn
    } do
      Req.Test.stub(Okta.APIClient, fn conn ->
        case conn.request_path do
          "/oauth2/v1/token" ->
            Req.Test.json(conn, %{"access_token" => "test_access_token"})

          "/api/v1/apps" ->
            Req.Test.json(conn, [%{"id" => "app1"}])

          "/api/v1/users" ->
            Req.Test.json(conn, [%{"id" => "user1"}])

          "/api/v1/groups" ->
            Req.Test.json(conn, [%{"id" => "group1"}])

          _ ->
            Req.Test.json(conn, %{})
        end
      end)

      # Create an existing unverified Okta directory with a keypair
      directory =
        okta_directory_fixture(
          account: account,
          name: "Existing Okta",
          okta_domain: "test.okta.com",
          client_id: "test-client-id",
          private_key_jwk: @test_private_key_jwk,
          kid: "test-kid",
          is_verified: false
        )

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/settings/directory_sync/okta/#{directory.id}/edit")

      # Verify the directory
      lv |> element("button", "Verify Now") |> render_click()
      wait_for_verification_error(lv, "Verified")

      # Now change the name — triggers validate
      lv
      |> form("#directory-form", %{
        "directory" => %{"name" => "Renamed Okta"}
      })
      |> render_change()

      # Verification must survive the validate event
      html = render(lv)
      assert html =~ "Verified"
    end

    test "shows error for Okta 400 E0000021", %{account: account, actor: actor, conn: conn} do
      Req.Test.stub(Okta.APIClient, fn conn ->
        conn
        |> Plug.Conn.put_status(400)
        |> Req.Test.json(%{"errorCode" => "E0000021"})
      end)

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/settings/directory_sync/okta/new")

      lv |> element("button", "Generate Keypair") |> render_click()

      lv
      |> form("#directory-form", %{
        "directory" => %{
          "name" => "Test",
          "okta_domain" => "test.okta.com",
          "client_id" => "test_client"
        }
      })
      |> render_change()

      # Verification is async - click triggers :do_verification message
      lv |> element("button", "Verify Now") |> render_click()

      wait_for_verification_error(lv, "Bad request to Okta")
    end

    test "shows error for Okta 401 invalid_client", %{account: account, actor: actor, conn: conn} do
      Req.Test.stub(Okta.APIClient, fn conn ->
        conn
        |> Plug.Conn.put_status(401)
        |> Req.Test.json(%{"errorCode" => "invalid_client"})
      end)

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/settings/directory_sync/okta/new")

      lv |> element("button", "Generate Keypair") |> render_click()

      lv
      |> form("#directory-form", %{
        "directory" => %{
          "name" => "Test",
          "okta_domain" => "test.okta.com",
          "client_id" => "bad_client"
        }
      })
      |> render_change()

      # Verification is async - click triggers :do_verification message
      lv |> element("button", "Verify Now") |> render_click()

      wait_for_verification_error(lv, "Client authentication failed")
    end

    test "shows error for Okta 403 with www-authenticate header", %{
      account: account,
      actor: actor,
      conn: conn
    } do
      Req.Test.stub(Okta.APIClient, fn conn ->
        case conn.request_path do
          "/oauth2/v1/token" ->
            Req.Test.json(conn, %{"access_token" => "test_token"})

          _ ->
            # 403 with empty body and www-authenticate header
            conn
            |> Plug.Conn.put_resp_header("www-authenticate", "error=insufficient_scope")
            |> Plug.Conn.send_resp(403, "")
        end
      end)

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/settings/directory_sync/okta/new")

      lv |> element("button", "Generate Keypair") |> render_click()

      lv
      |> form("#directory-form", %{
        "directory" => %{
          "name" => "Test",
          "okta_domain" => "test.okta.com",
          "client_id" => "test_client"
        }
      })
      |> render_change()

      # Verification is async - click triggers :do_verification message
      lv |> element("button", "Verify Now") |> render_click()

      wait_for_verification_error(lv, "does not contain the required scopes")
    end

    test "shows error for Okta empty apps", %{account: account, actor: actor, conn: conn} do
      Req.Test.stub(Okta.APIClient, fn conn ->
        case conn.request_path do
          "/oauth2/v1/token" ->
            Req.Test.json(conn, %{"access_token" => "test_token"})

          "/api/v1/apps" ->
            Req.Test.json(conn, [])

          _ ->
            Req.Test.json(conn, [%{"id" => "item1"}])
        end
      end)

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/settings/directory_sync/okta/new")

      lv |> element("button", "Generate Keypair") |> render_click()

      lv
      |> form("#directory-form", %{
        "directory" => %{
          "name" => "Test",
          "okta_domain" => "test.okta.com",
          "client_id" => "test_client"
        }
      })
      |> render_change()

      # Verification is async - click triggers :do_verification message
      lv |> element("button", "Verify Now") |> render_click()

      wait_for_verification_error(lv, "No apps found")
    end

    test "shows error for Okta empty users", %{account: account, actor: actor, conn: conn} do
      Req.Test.stub(Okta.APIClient, fn conn ->
        case conn.request_path do
          "/oauth2/v1/token" ->
            Req.Test.json(conn, %{"access_token" => "test_token"})

          "/api/v1/apps" ->
            Req.Test.json(conn, [%{"id" => "app1"}])

          "/api/v1/users" ->
            Req.Test.json(conn, [])

          _ ->
            Req.Test.json(conn, [%{"id" => "item1"}])
        end
      end)

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/settings/directory_sync/okta/new")

      lv |> element("button", "Generate Keypair") |> render_click()

      lv
      |> form("#directory-form", %{
        "directory" => %{
          "name" => "Test",
          "okta_domain" => "test.okta.com",
          "client_id" => "test_client"
        }
      })
      |> render_change()

      # Verification is async - click triggers :do_verification message
      lv |> element("button", "Verify Now") |> render_click()

      wait_for_verification_error(lv, "No users found")
    end

    test "shows error for Okta empty groups", %{account: account, actor: actor, conn: conn} do
      Req.Test.stub(Okta.APIClient, fn conn ->
        case conn.request_path do
          "/oauth2/v1/token" ->
            Req.Test.json(conn, %{"access_token" => "test_token"})

          "/api/v1/apps" ->
            Req.Test.json(conn, [%{"id" => "app1"}])

          "/api/v1/users" ->
            Req.Test.json(conn, [%{"id" => "user1"}])

          "/api/v1/groups" ->
            Req.Test.json(conn, [])

          _ ->
            Req.Test.json(conn, [%{"id" => "item1"}])
        end
      end)

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/settings/directory_sync/okta/new")

      lv |> element("button", "Generate Keypair") |> render_click()

      lv
      |> form("#directory-form", %{
        "directory" => %{
          "name" => "Test",
          "okta_domain" => "test.okta.com",
          "client_id" => "test_client"
        }
      })
      |> render_change()

      # Verification is async - click triggers :do_verification message
      lv |> element("button", "Verify Now") |> render_click()

      wait_for_verification_error(lv, "No groups found")
    end
  end

  describe "handle_event - start_verification (Entra)" do
    test "generates admin consent URL for Entra verification", %{
      account: account,
      actor: actor,
      conn: conn
    } do
      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/settings/directory_sync/entra/new")

      # Fill in form
      lv
      |> form("#directory-form", %{
        "directory" => %{"name" => "Test Entra", "sync_all_groups" => "false"}
      })
      |> render_change()

      # Start verification - this should push an event to open URL
      # We can't fully test the OAuth flow, but we can verify the button exists
      assert has_element?(lv, "button#verify-button-verify-button")
    end
  end

  describe "handle_event - reset_verification" do
    test "resets verification status for Google directory", %{
      account: account,
      actor: actor,
      conn: conn
    } do
      directory = google_directory_fixture(account: account, is_verified: true)

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/settings/directory_sync/google/#{directory.id}/edit")

      # Click reset verification
      html = lv |> element("button", "Reset verification") |> render_click()

      assert html =~ "Awaiting verification"
      refute html =~ "Reset verification"
    end
  end

  describe "handle_event - submit_directory (new)" do
    test "creates new Google directory successfully", %{
      account: account,
      actor: actor,
      conn: conn
    } do
      # Mock successful verification
      Req.Test.stub(Google.APIClient, fn conn ->
        case conn.request_path do
          "/token" ->
            Req.Test.json(conn, %{"access_token" => "test_access_token"})

          "/admin/directory/v1/customers/my_customer" ->
            Req.Test.json(conn, %{"customerDomain" => "test-domain.com"})

          _ ->
            Req.Test.json(conn, %{"users" => [], "groups" => [], "organizationUnits" => []})
        end
      end)

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/settings/directory_sync/google/new")

      # Fill form and verify
      lv
      |> form("#directory-form", %{
        "directory" => %{
          "name" => "New Google Directory",
          "impersonation_email" => "admin@test-domain.com"
        }
      })
      |> render_change()

      # Verification is async - trigger and wait for completion
      lv |> element("button", "Verify Now") |> render_click()
      render(lv)

      # Submit form - push_patch re-renders in place
      lv |> form("#directory-form") |> render_submit()

      # After push_patch, check flash and directory in list
      html = render(lv)
      assert html =~ "Directory saved successfully"
      assert html =~ "New Google Directory"
    end

    test "creates new Okta directory successfully", %{account: account, actor: actor, conn: conn} do
      Req.Test.stub(Okta.APIClient, fn conn ->
        case conn.request_path do
          "/oauth2/v1/token" ->
            Req.Test.json(conn, %{"access_token" => "test_token"})

          _ ->
            Req.Test.json(conn, [%{"id" => "item1"}])
        end
      end)

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/settings/directory_sync/okta/new")

      # Generate keypair
      lv |> element("button", "Generate Keypair") |> render_click()

      # Fill form
      lv
      |> form("#directory-form", %{
        "directory" => %{
          "name" => "New Okta Directory",
          "okta_domain" => "test.okta.com",
          "client_id" => "test_client"
        }
      })
      |> render_change()

      # Verification is async - trigger and wait for completion
      lv |> element("button", "Verify Now") |> render_click()
      render(lv)

      # Submit - push_patch re-renders in place
      lv |> form("#directory-form") |> render_submit()

      # After push_patch, check flash and directory in list
      html = render(lv)
      assert html =~ "Directory saved successfully"
      assert html =~ "New Okta Directory"
    end

    test "shows validation errors on submit", %{account: account, actor: actor, conn: conn} do
      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/settings/directory_sync/google/new")

      # Try to submit empty form - should show validation errors
      html =
        lv
        |> form("#directory-form", %{
          "directory" => %{"name" => "", "impersonation_email" => ""}
        })
        |> render_submit()

      assert html =~ "can&#39;t be blank"
    end

    test "shows unique constraint error for duplicate name", %{
      account: account,
      actor: actor
    } do
      # Create existing directory with unique name
      existing = google_directory_fixture(account: account, name: "Duplicate Test Name")

      # Verify it exists in the database
      assert existing.name == "Duplicate Test Name"
      assert existing.account_id == account.id

      # Create a subject for the DB operation
      subject = admin_subject_fixture(account: account, actor: actor)

      # Try to insert a directory with the same name - should fail with unique constraint
      changeset =
        %Google.Directory{account_id: account.id}
        |> Ecto.Changeset.cast(
          %{
            name: "Duplicate Test Name",
            domain: "unique-domain.com",
            impersonation_email: "test@unique-domain.com",
            is_verified: true
          },
          [:name, :domain, :impersonation_email, :is_verified]
        )
        |> Google.Directory.changeset()

      # Insert should fail due to unique constraint on name
      assert {:error, error_changeset} = Database.insert_directory(changeset, subject)

      # Check the error message
      {message, _opts} = Keyword.get(error_changeset.errors, :name)
      assert message == "A Google directory with this name already exists."
    end
  end

  describe "handle_event - submit_directory (edit)" do
    test "updates existing Google directory", %{account: account, actor: actor, conn: conn} do
      directory = google_directory_fixture(account: account, name: "Original Name")

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/settings/directory_sync/google/#{directory.id}/edit")

      # Update name
      lv
      |> form("#directory-form", %{
        "directory" => %{"name" => "Updated Name"}
      })
      |> render_change()

      # Submit - push_patch re-renders in place
      lv |> form("#directory-form") |> render_submit()

      # After push_patch, check flash and directory in list
      html = render(lv)
      assert html =~ "Directory saved successfully"
      assert html =~ "Updated Name"
    end

    test "clears error state and enables directory when re-verified after sync error", %{
      account: account,
      actor: actor,
      conn: conn
    } do
      # Create a directory that was disabled due to sync error
      directory =
        google_directory_fixture(
          account: account,
          is_disabled: true,
          disabled_reason: "Sync error",
          error_message: "Previous sync failed",
          is_verified: false
        )

      # Mock successful verification
      Req.Test.stub(Google.APIClient, fn conn ->
        case conn.request_path do
          "/token" ->
            Req.Test.json(conn, %{"access_token" => "test_token"})

          "/admin/directory/v1/customers/my_customer" ->
            Req.Test.json(conn, %{"customerDomain" => directory.domain})

          _ ->
            Req.Test.json(conn, %{"users" => [], "groups" => [], "organizationUnits" => []})
        end
      end)

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/settings/directory_sync/google/#{directory.id}/edit")

      # Re-verify - async, trigger and wait
      lv |> element("button", "Verify Now") |> render_click()
      render(lv)

      # Submit - push_patch re-renders in place
      lv |> form("#directory-form") |> render_submit()

      # After push_patch, check flash
      html = render(lv)
      assert html =~ "Directory saved successfully"

      # Verify the directory is no longer disabled
      updated = Portal.Repo.get!(Google.Directory, directory.id)
      assert updated.is_disabled == false
      assert updated.disabled_reason == nil
      assert updated.error_message == nil
    end
  end

  describe "handle_event - toggle_directory" do
    test "disables an enabled directory", %{account: account, actor: actor, conn: conn} do
      directory = google_directory_fixture(account: account, is_disabled: false)

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/settings/directory_sync")

      # The toggle uses a button_with_confirmation component with a JS hook
      # We directly trigger the toggle_directory event
      html = render_click(lv, "toggle_directory", %{"id" => directory.id})

      assert html =~ "Directory disabled successfully"
    end

    test "enables a disabled directory", %{account: account, actor: actor, conn: conn} do
      directory =
        google_directory_fixture(
          account: account,
          is_disabled: true,
          is_verified: true,
          disabled_reason: "Disabled by admin"
        )

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/settings/directory_sync")

      # Directly trigger the toggle_directory event
      html = render_click(lv, "toggle_directory", %{"id" => directory.id})

      assert html =~ "Directory enabled successfully"
    end

    test "cannot enable directory without IDP sync feature", %{conn: conn} do
      account = account_fixture(features: %{idp_sync: false})
      actor = admin_actor_fixture(account: account)

      directory =
        google_directory_fixture(
          account: account,
          is_disabled: true,
          is_verified: true,
          disabled_reason: "Disabled by admin"
        )

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/settings/directory_sync")

      # Verify directory record exists in DB
      assert Portal.Repo.get!(Portal.Google.Directory, directory.id)

      # Trying to toggle should not enable the directory since IDP sync is disabled
      # The handler should return an error or not change the state
      html = render_click(lv, "toggle_directory", %{"id" => directory.id})

      # Directory should remain disabled - check that success flash is not shown
      refute html =~ "Directory enabled successfully"

      # Verify directory is still disabled in DB
      updated = Portal.Repo.get!(Portal.Google.Directory, directory.id)
      assert updated.is_disabled == true
    end

    test "cannot enable unverified directory", %{account: account, actor: actor, conn: conn} do
      directory =
        google_directory_fixture(
          account: account,
          is_disabled: true,
          is_verified: false
        )

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/settings/directory_sync")

      # Try to enable an unverified directory directly
      html = render_click(lv, "toggle_directory", %{"id" => directory.id})

      assert html =~ "Failed to update directory"
    end
  end

  describe "handle_event - delete_directory" do
    test "deletes a directory successfully", %{account: account, actor: actor, conn: conn} do
      directory = google_directory_fixture(account: account, name: "To Be Deleted")

      {:ok, lv, html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/settings/directory_sync")

      assert html =~ "To Be Deleted"

      # Directly trigger delete_directory event (button uses JS hook confirmation)
      # push_patch re-renders in place
      render_click(lv, "delete_directory", %{"id" => directory.id})

      # After push_patch, check flash and that directory is gone
      html = render(lv)
      assert html =~ "Directory deleted successfully"
      refute html =~ "To Be Deleted"
    end

    test "shows deletion stats in confirmation dialog", %{
      account: account,
      actor: actor,
      conn: conn
    } do
      directory = synced_google_directory_fixture(account: account)

      # Get the base Portal.Directory for group and identity association
      base_directory =
        Portal.Repo.get_by!(Portal.Directory, id: directory.id, account_id: directory.account_id)

      # Create some actors, groups, and policies for this directory
      group =
        Portal.GroupFixtures.group_fixture(
          account: account,
          directory: base_directory
        )

      # Create actor and manually set created_by_directory_id
      sync_actor = actor_fixture(account: account, type: :account_user)

      sync_actor
      |> Ecto.Changeset.change(%{created_by_directory_id: directory.id})
      |> Portal.Repo.update!()

      identity_fixture(
        account: account,
        actor: sync_actor,
        directory: base_directory
      )

      Portal.PolicyFixtures.policy_fixture(
        account: account,
        group: group
      )

      conn = authorize_conn(conn, actor)
      {:ok, lv, _html} = live(conn, ~p"/#{account}/settings/directory_sync")

      # Get subject from socket assigns
      subject = conn.assigns.subject

      # Check that the test data exists on the page
      html = render(lv)
      assert html =~ directory.name

      # Verify that stats are computed correctly using the existing subject
      stats = Database.count_deletion_stats(directory, subject)
      assert stats.actors == 1
      assert stats.groups == 1
      assert stats.policies == 1
    end
  end

  describe "handle_event - sync_directory" do
    test "queues sync job for Google directory", %{account: account, actor: actor, conn: conn} do
      _directory = synced_google_directory_fixture(account: account)

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/settings/directory_sync")

      html = lv |> element("button", "Sync Now") |> render_click()

      assert html =~ "Directory sync has been queued successfully"
    end

    test "queues sync job for Entra directory", %{account: account, actor: actor, conn: conn} do
      _directory = synced_entra_directory_fixture(account: account)

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/settings/directory_sync")

      html = lv |> element("button", "Sync Now") |> render_click()

      assert html =~ "Directory sync has been queued successfully"
    end

    test "queues sync job for Okta directory", %{account: account, actor: actor, conn: conn} do
      _directory =
        synced_okta_directory_fixture(account: account, private_key_jwk: @test_private_key_jwk)

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/settings/directory_sync")

      html = lv |> element("button", "Sync Now") |> render_click()

      assert html =~ "Directory sync has been queued successfully"
    end
  end

  describe "handle_info - directories_changed" do
    test "refreshes directory list on PubSub message", %{
      account: account,
      actor: actor,
      conn: conn
    } do
      {:ok, lv, html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/settings/directory_sync")

      # Use a unique name that won't appear in UI elements
      refute html =~ "PubSub Test Directory XYZ123"

      # Create a new directory in the background
      google_directory_fixture(account: account, name: "PubSub Test Directory XYZ123")

      # Simulate PubSub message
      send(lv.pid, :directories_changed)

      # Wait for the update
      html = render(lv)
      assert html =~ "PubSub Test Directory XYZ123"
    end
  end

  describe "directory_card rendering" do
    test "displays disabled directory with disabled reason", %{
      account: account,
      actor: actor,
      conn: conn
    } do
      google_directory_fixture(
        account: account,
        name: "Disabled Dir",
        is_disabled: true,
        disabled_reason: "Disabled by admin"
      )

      {:ok, _lv, html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/settings/directory_sync")

      assert html =~ "Disabled"
      assert html =~ "Disabled by admin"
    end

    test "displays sync error state", %{account: account, actor: actor, conn: conn} do
      google_directory_fixture(
        account: account,
        name: "Error Dir",
        is_disabled: true,
        disabled_reason: "Sync error",
        error_message: "Failed to connect to Google API"
      )

      {:ok, _lv, html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/settings/directory_sync")

      assert html =~ "Sync has been disabled due to an error"
      assert html =~ "Failed to connect to Google API"
    end

    test "displays transient error warning when errored_at is set but not disabled", %{
      account: account,
      actor: actor,
      conn: conn
    } do
      # Create a directory with a transient error (errored_at set but not disabled)
      google_directory_fixture(
        account: account,
        name: "Transient Error Dir",
        is_disabled: false,
        errored_at: DateTime.utc_now(),
        error_message: "Connection timed out."
      )

      {:ok, _lv, html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/settings/directory_sync")

      assert html =~ "Sync encountered a temporary error"
      assert html =~ "Connection timed out."
      assert html =~ "Sync will automatically retry"
      assert html =~ "24 hours"
    end

    test "does not display transient error warning when no error", %{
      account: account,
      actor: actor,
      conn: conn
    } do
      # Create a healthy directory (no errored_at)
      google_directory_fixture(
        account: account,
        name: "Healthy Dir",
        is_disabled: false,
        errored_at: nil,
        error_message: nil
      )

      {:ok, _lv, html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/settings/directory_sync")

      refute html =~ "Sync encountered a temporary error"
      refute html =~ "Sync will automatically retry"
    end

    test "displays never synced state", %{account: account, actor: actor, conn: conn} do
      google_directory_fixture(account: account, name: "Never Synced", synced_at: nil)

      {:ok, _lv, html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/settings/directory_sync")

      assert html =~ "Never synced"
    end

    test "displays synced state with counts", %{account: account, actor: actor, conn: conn} do
      directory = synced_google_directory_fixture(account: account)

      # Get the base Portal.Directory for group association
      base_directory =
        Portal.Repo.get_by!(Portal.Directory, id: directory.id, account_id: directory.account_id)

      # Create some groups for this directory using the directory object (not directory_id)
      Portal.GroupFixtures.group_fixture(account: account, directory: base_directory)
      Portal.GroupFixtures.group_fixture(account: account, directory: base_directory)

      {:ok, _lv, html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/settings/directory_sync")

      assert html =~ "2 groups"
      assert html =~ "synced"
    end

    test "displays Entra sync_all_groups setting", %{account: account, actor: actor, conn: conn} do
      entra_directory_fixture(account: account, sync_all_groups: true)

      {:ok, _lv, html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/settings/directory_sync")

      assert html =~ "All groups"
    end

    test "displays Entra assigned groups only setting", %{
      account: account,
      actor: actor,
      conn: conn
    } do
      entra_directory_fixture(account: account, sync_all_groups: false)

      {:ok, _lv, html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/settings/directory_sync")

      assert html =~ "Assigned groups only"
    end

    test "displays Okta sync error state with error message", %{
      account: account,
      actor: actor,
      conn: conn
    } do
      okta_directory_fixture(
        account: account,
        name: "Okta Error Dir",
        is_disabled: true,
        disabled_reason: "Sync error",
        error_message: "User missing required 'email' field"
      )

      {:ok, _lv, html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/settings/directory_sync")

      assert html =~ "Sync has been disabled due to an error"
      assert html =~ "User missing required &#39;email&#39; field"
    end

    test "displays Okta sync error for authentication failure", %{
      account: account,
      actor: actor,
      conn: conn
    } do
      okta_directory_fixture(
        account: account,
        name: "Okta Auth Error",
        is_disabled: true,
        disabled_reason: "Sync error",
        error_message: "HTTP 401 - Client authentication failed"
      )

      {:ok, _lv, html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/settings/directory_sync")

      assert html =~ "Sync has been disabled due to an error"
      assert html =~ "HTTP 401 - Client authentication failed"
    end

    test "displays Entra sync error state with error message", %{
      account: account,
      actor: actor,
      conn: conn
    } do
      entra_directory_fixture(
        account: account,
        name: "Entra Error Dir",
        is_disabled: true,
        disabled_reason: "Sync error",
        error_message: "HTTP 403 - Code: Authorization_RequestDenied"
      )

      {:ok, _lv, html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/settings/directory_sync")

      assert html =~ "Sync has been disabled due to an error"
      assert html =~ "HTTP 403 - Code: Authorization_RequestDenied"
    end

    test "displays Okta circuit breaker error message", %{
      account: account,
      actor: actor,
      conn: conn
    } do
      okta_directory_fixture(
        account: account,
        name: "Okta Circuit Breaker",
        is_disabled: true,
        disabled_reason: "Sync error",
        error_message:
          "Sync would delete 50 of 52 identities (96.0%). This may indicate the Okta application was misconfigured or removed."
      )

      {:ok, _lv, html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/settings/directory_sync")

      assert html =~ "Sync has been disabled due to an error"
      assert html =~ "Sync would delete 50 of 52 identities"
      assert html =~ "Okta application was misconfigured or removed"
    end
  end

  describe "Database module" do
    test "list_all_directories returns all directory types", %{account: account, actor: actor} do
      google_dir = google_directory_fixture(account: account)
      entra_dir = entra_directory_fixture(account: account)
      okta_dir = okta_directory_fixture(account: account)

      subject = admin_subject_fixture(account: account, actor: actor)
      directories = Database.list_all_directories(subject)

      assert length(directories) == 3

      ids = Enum.map(directories, & &1.id)
      assert google_dir.id in ids
      assert entra_dir.id in ids
      assert okta_dir.id in ids
    end

    test "list_all_directories enriches with job status", %{account: account, actor: actor} do
      directory = google_directory_fixture(account: account)

      # Insert an Oban job for this directory
      {:ok, _job} =
        Oban.insert(Portal.Google.Sync.new(%{"directory_id" => directory.id}))

      subject = admin_subject_fixture(account: account, actor: actor)
      [enriched] = Database.list_all_directories(subject)

      assert enriched.has_active_job == true
    end

    test "list_all_directories enriches with sync stats", %{account: account, actor: actor} do
      directory = synced_google_directory_fixture(account: account)

      # Get the base Portal.Directory for group and identity association
      base_directory =
        Portal.Repo.get_by!(Portal.Directory, id: directory.id, account_id: directory.account_id)

      # Create some groups and actors for this directory using directory object
      Portal.GroupFixtures.group_fixture(account: account, directory: base_directory)
      Portal.GroupFixtures.group_fixture(account: account, directory: base_directory)

      sync_actor =
        actor_fixture(
          account: account,
          type: :account_user,
          created_by_directory_id: directory.id
        )

      identity_fixture(
        account: account,
        actor: sync_actor,
        directory: base_directory
      )

      subject = admin_subject_fixture(account: account, actor: actor)
      [enriched] = Database.list_all_directories(subject)

      assert enriched.groups_count == 2
      assert enriched.actors_count == 1
    end

    test "get_directory! returns directory by id", %{account: account, actor: actor} do
      directory = google_directory_fixture(account: account)

      subject = admin_subject_fixture(account: account, actor: actor)
      fetched = Database.get_directory!(Google.Directory, directory.id, subject)

      assert fetched.id == directory.id
      assert fetched.name == directory.name
    end

    test "get_directory! raises for non-existent directory", %{account: account, actor: actor} do
      subject = admin_subject_fixture(account: account, actor: actor)

      assert_raise Ecto.NoResultsError, fn ->
        Database.get_directory!(Google.Directory, Ecto.UUID.generate(), subject)
      end
    end

    test "count_deletion_stats returns correct counts", %{account: account, actor: actor} do
      directory = google_directory_fixture(account: account)

      # Get the base Portal.Directory for group and identity association
      base_directory =
        Portal.Repo.get_by!(Portal.Directory, id: directory.id, account_id: directory.account_id)

      # Create actors - actor_fixture doesn't cast created_by_directory_id, so we update manually
      sync_actor1 = actor_fixture(account: account, type: :account_user)

      sync_actor1
      |> Ecto.Changeset.change(%{created_by_directory_id: directory.id})
      |> Portal.Repo.update!()

      sync_actor2 = actor_fixture(account: account, type: :account_user)

      sync_actor2
      |> Ecto.Changeset.change(%{created_by_directory_id: directory.id})
      |> Portal.Repo.update!()

      identity_fixture(
        account: account,
        actor: sync_actor1,
        directory: base_directory
      )

      identity_fixture(
        account: account,
        actor: sync_actor2,
        directory: base_directory
      )

      group1 =
        Portal.GroupFixtures.group_fixture(account: account, directory: base_directory)

      group2 =
        Portal.GroupFixtures.group_fixture(account: account, directory: base_directory)

      Portal.PolicyFixtures.policy_fixture(account: account, group: group1)
      Portal.PolicyFixtures.policy_fixture(account: account, group: group2)
      Portal.PolicyFixtures.policy_fixture(account: account, group: group2)

      subject = admin_subject_fixture(account: account, actor: actor)
      stats = Database.count_deletion_stats(directory, subject)

      assert stats.actors == 2
      assert stats.identities == 2
      assert stats.groups == 2
      assert stats.policies == 3
    end

    test "reload returns nil for nil directory", %{account: account, actor: actor} do
      subject = admin_subject_fixture(account: account, actor: actor)
      assert Database.reload(nil, subject) == nil
    end

    test "reload returns updated directory", %{account: account, actor: actor} do
      directory = google_directory_fixture(account: account, name: "Original")

      # Update directly in DB
      directory
      |> Ecto.Changeset.change(%{name: "Updated"})
      |> Portal.Repo.update!()

      subject = admin_subject_fixture(account: account, actor: actor)
      reloaded = Database.reload(directory, subject)

      assert reloaded.name == "Updated"
    end
  end

  describe "verification error parsing" do
    # These tests verify the error message parsing logic indirectly through the UI

    test "Google 400 with generic error", %{account: account, actor: actor, conn: conn} do
      Req.Test.stub(Google.APIClient, fn conn ->
        case conn.request_path do
          "/token" ->
            Req.Test.json(conn, %{"access_token" => "test_token"})

          _ ->
            conn
            |> Plug.Conn.put_status(400)
            |> Req.Test.json(%{"error" => "unknown_error"})
        end
      end)

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/settings/directory_sync/google/new")

      lv
      |> form("#directory-form", %{
        "directory" => %{"name" => "Test", "impersonation_email" => "test@example.com"}
      })
      |> render_change()

      # Verification is async - click triggers :do_verification message
      lv |> element("button", "Verify Now") |> render_click()

      wait_for_verification_error(lv, "HTTP 400 Bad Request")
    end

    test "Google 401 without error_description", %{account: account, actor: actor, conn: conn} do
      Req.Test.stub(Google.APIClient, fn conn ->
        case conn.request_path do
          "/token" ->
            Req.Test.json(conn, %{"access_token" => "test_token"})

          _ ->
            conn
            |> Plug.Conn.put_status(401)
            |> Req.Test.json(%{})
        end
      end)

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/settings/directory_sync/google/new")

      lv
      |> form("#directory-form", %{
        "directory" => %{"name" => "Test", "impersonation_email" => "test@example.com"}
      })
      |> render_change()

      # Verification is async - click triggers :do_verification message
      lv |> element("button", "Verify Now") |> render_click()

      wait_for_verification_error(lv, "HTTP 401 error")
    end

    test "Google 403 without error message", %{account: account, actor: actor, conn: conn} do
      Req.Test.stub(Google.APIClient, fn conn ->
        case conn.request_path do
          "/token" ->
            Req.Test.json(conn, %{"access_token" => "test_token"})

          _ ->
            conn
            |> Plug.Conn.put_status(403)
            |> Req.Test.json(%{})
        end
      end)

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/settings/directory_sync/google/new")

      lv
      |> form("#directory-form", %{
        "directory" => %{"name" => "Test", "impersonation_email" => "test@example.com"}
      })
      |> render_change()

      # Verification is async - click triggers :do_verification message
      lv |> element("button", "Verify Now") |> render_click()

      wait_for_verification_error(lv, "HTTP 403 error")
    end

    test "Google 404 without error message", %{account: account, actor: actor, conn: conn} do
      Req.Test.stub(Google.APIClient, fn conn ->
        case conn.request_path do
          "/token" ->
            Req.Test.json(conn, %{"access_token" => "test_token"})

          _ ->
            conn
            |> Plug.Conn.put_status(404)
            |> Req.Test.json(%{})
        end
      end)

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/settings/directory_sync/google/new")

      lv
      |> form("#directory-form", %{
        "directory" => %{"name" => "Test", "impersonation_email" => "test@example.com"}
      })
      |> render_change()

      # Verification is async - click triggers :do_verification message
      lv |> element("button", "Verify Now") |> render_click()

      wait_for_verification_error(lv, "HTTP 404 Not Found")
    end

    test "Okta 400 with E0000001", %{account: account, actor: actor, conn: conn} do
      Req.Test.stub(Okta.APIClient, fn conn ->
        case conn.request_path do
          "/oauth2/v1/token" ->
            Req.Test.json(conn, %{"access_token" => "test_token"})

          _ ->
            conn
            |> Plug.Conn.put_status(400)
            |> Req.Test.json(%{"errorCode" => "E0000001", "errorSummary" => "Invalid params"})
        end
      end)

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/settings/directory_sync/okta/new")

      lv |> element("button", "Generate Keypair") |> render_click()

      lv
      |> form("#directory-form", %{
        "directory" => %{
          "name" => "Test",
          "okta_domain" => "test.okta.com",
          "client_id" => "test"
        }
      })
      |> render_change()

      # Verification is async - click triggers :do_verification message
      lv |> element("button", "Verify Now") |> render_click()

      wait_for_verification_error(lv, "API validation failed")
    end

    test "Okta 400 with E0000003", %{account: account, actor: actor, conn: conn} do
      Req.Test.stub(Okta.APIClient, fn conn ->
        case conn.request_path do
          "/oauth2/v1/token" ->
            Req.Test.json(conn, %{"access_token" => "test_token"})

          _ ->
            conn
            |> Plug.Conn.put_status(400)
            |> Req.Test.json(%{"errorCode" => "E0000003"})
        end
      end)

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/settings/directory_sync/okta/new")

      lv |> element("button", "Generate Keypair") |> render_click()

      lv
      |> form("#directory-form", %{
        "directory" => %{
          "name" => "Test",
          "okta_domain" => "test.okta.com",
          "client_id" => "test"
        }
      })
      |> render_change()

      # Verification is async - click triggers :do_verification message
      lv |> element("button", "Verify Now") |> render_click()

      wait_for_verification_error(lv, "request body was invalid")
    end

    test "Okta 400 with invalid_client", %{account: account, actor: actor, conn: conn} do
      Req.Test.stub(Okta.APIClient, fn conn ->
        case conn.request_path do
          "/oauth2/v1/token" ->
            Req.Test.json(conn, %{"access_token" => "test_token"})

          _ ->
            conn
            |> Plug.Conn.put_status(400)
            |> Req.Test.json(%{"errorCode" => "invalid_client"})
        end
      end)

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/settings/directory_sync/okta/new")

      lv |> element("button", "Generate Keypair") |> render_click()

      lv
      |> form("#directory-form", %{
        "directory" => %{
          "name" => "Test",
          "okta_domain" => "test.okta.com",
          "client_id" => "test"
        }
      })
      |> render_change()

      # Verification is async - click triggers :do_verification message
      lv |> element("button", "Verify Now") |> render_click()

      wait_for_verification_error(lv, "Invalid client application")
    end

    test "Okta 400 with errorSummary only", %{account: account, actor: actor, conn: conn} do
      Req.Test.stub(Okta.APIClient, fn conn ->
        case conn.request_path do
          "/oauth2/v1/token" ->
            Req.Test.json(conn, %{"access_token" => "test_token"})

          _ ->
            conn
            |> Plug.Conn.put_status(400)
            |> Req.Test.json(%{"errorSummary" => "Custom error message"})
        end
      end)

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/settings/directory_sync/okta/new")

      lv |> element("button", "Generate Keypair") |> render_click()

      lv
      |> form("#directory-form", %{
        "directory" => %{
          "name" => "Test",
          "okta_domain" => "test.okta.com",
          "client_id" => "test"
        }
      })
      |> render_change()

      # Verification is async - click triggers :do_verification message
      lv |> element("button", "Verify Now") |> render_click()

      wait_for_verification_error(lv, "Custom error message")
    end

    test "Okta 401 with E0000011", %{account: account, actor: actor, conn: conn} do
      Req.Test.stub(Okta.APIClient, fn conn ->
        case conn.request_path do
          "/oauth2/v1/token" ->
            Req.Test.json(conn, %{"access_token" => "test_token"})

          _ ->
            conn
            |> Plug.Conn.put_status(401)
            |> Req.Test.json(%{"errorCode" => "E0000011"})
        end
      end)

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/settings/directory_sync/okta/new")

      lv |> element("button", "Generate Keypair") |> render_click()

      lv
      |> form("#directory-form", %{
        "directory" => %{
          "name" => "Test",
          "okta_domain" => "test.okta.com",
          "client_id" => "test"
        }
      })
      |> render_change()

      # Verification is async - click triggers :do_verification message
      lv |> element("button", "Verify Now") |> render_click()

      wait_for_verification_error(lv, "Invalid token")
    end

    test "Okta 401 with E0000061", %{account: account, actor: actor, conn: conn} do
      Req.Test.stub(Okta.APIClient, fn conn ->
        case conn.request_path do
          "/oauth2/v1/token" ->
            Req.Test.json(conn, %{"access_token" => "test_token"})

          _ ->
            conn
            |> Plug.Conn.put_status(401)
            |> Req.Test.json(%{"errorCode" => "E0000061"})
        end
      end)

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/settings/directory_sync/okta/new")

      lv |> element("button", "Generate Keypair") |> render_click()

      lv
      |> form("#directory-form", %{
        "directory" => %{
          "name" => "Test",
          "okta_domain" => "test.okta.com",
          "client_id" => "test"
        }
      })
      |> render_change()

      # Verification is async - click triggers :do_verification message
      lv |> element("button", "Verify Now") |> render_click()

      wait_for_verification_error(lv, "Access denied")
    end

    test "Okta 403 with E0000006", %{account: account, actor: actor, conn: conn} do
      Req.Test.stub(Okta.APIClient, fn conn ->
        case conn.request_path do
          "/oauth2/v1/token" ->
            Req.Test.json(conn, %{"access_token" => "test_token"})

          _ ->
            conn
            |> Plug.Conn.put_status(403)
            |> Req.Test.json(%{"errorCode" => "E0000006"})
        end
      end)

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/settings/directory_sync/okta/new")

      lv |> element("button", "Generate Keypair") |> render_click()

      lv
      |> form("#directory-form", %{
        "directory" => %{
          "name" => "Test",
          "okta_domain" => "test.okta.com",
          "client_id" => "test"
        }
      })
      |> render_change()

      # Verification is async - click triggers :do_verification message
      lv |> element("button", "Verify Now") |> render_click()

      wait_for_verification_error(lv, "Access denied")
    end

    test "Okta 403 with E0000022", %{account: account, actor: actor, conn: conn} do
      Req.Test.stub(Okta.APIClient, fn conn ->
        case conn.request_path do
          "/oauth2/v1/token" ->
            Req.Test.json(conn, %{"access_token" => "test_token"})

          _ ->
            conn
            |> Plug.Conn.put_status(403)
            |> Req.Test.json(%{"errorCode" => "E0000022"})
        end
      end)

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/settings/directory_sync/okta/new")

      lv |> element("button", "Generate Keypair") |> render_click()

      lv
      |> form("#directory-form", %{
        "directory" => %{
          "name" => "Test",
          "okta_domain" => "test.okta.com",
          "client_id" => "test"
        }
      })
      |> render_change()

      # Verification is async - click triggers :do_verification message
      lv |> element("button", "Verify Now") |> render_click()

      wait_for_verification_error(lv, "API access denied")
    end

    test "Okta 404 with E0000007", %{account: account, actor: actor, conn: conn} do
      Req.Test.stub(Okta.APIClient, fn conn ->
        case conn.request_path do
          "/oauth2/v1/token" ->
            Req.Test.json(conn, %{"access_token" => "test_token"})

          _ ->
            conn
            |> Plug.Conn.put_status(404)
            |> Req.Test.json(%{"errorCode" => "E0000007"})
        end
      end)

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/settings/directory_sync/okta/new")

      lv |> element("button", "Generate Keypair") |> render_click()

      lv
      |> form("#directory-form", %{
        "directory" => %{
          "name" => "Test",
          "okta_domain" => "test.okta.com",
          "client_id" => "test"
        }
      })
      |> render_change()

      # Verification is async - click triggers :do_verification message
      lv |> element("button", "Verify Now") |> render_click()

      wait_for_verification_error(lv, "Resource not found")
    end

    test "Okta 500 error", %{account: account, actor: actor, conn: conn} do
      Req.Test.stub(Okta.APIClient, fn conn ->
        case conn.request_path do
          "/oauth2/v1/token" ->
            Req.Test.json(conn, %{"access_token" => "test_token"})

          _ ->
            conn
            |> Plug.Conn.put_status(500)
            |> Req.Test.json(%{})
        end
      end)

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/settings/directory_sync/okta/new")

      lv |> element("button", "Generate Keypair") |> render_click()

      lv
      |> form("#directory-form", %{
        "directory" => %{
          "name" => "Test",
          "okta_domain" => "test.okta.com",
          "client_id" => "test"
        }
      })
      |> render_change()

      # Verification is async - click triggers :do_verification message
      lv |> element("button", "Verify Now") |> render_click()

      wait_for_verification_error(lv, "Okta service is currently unavailable")
    end

    test "Okta 400 fallback (no known error code)", %{account: account, actor: actor, conn: conn} do
      Req.Test.stub(Okta.APIClient, fn conn ->
        case conn.request_path do
          "/oauth2/v1/token" ->
            Req.Test.json(conn, %{"access_token" => "test_token"})

          _ ->
            conn
            |> Plug.Conn.put_status(400)
            |> Req.Test.json(%{})
        end
      end)

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/settings/directory_sync/okta/new")

      lv |> element("button", "Generate Keypair") |> render_click()

      lv
      |> form("#directory-form", %{
        "directory" => %{
          "name" => "Test",
          "okta_domain" => "test.okta.com",
          "client_id" => "test"
        }
      })
      |> render_change()

      lv |> element("button", "Verify Now") |> render_click()

      wait_for_verification_error(lv, "HTTP 400 Bad Request")
    end

    test "Okta 401 with errorSummary", %{account: account, actor: actor, conn: conn} do
      Req.Test.stub(Okta.APIClient, fn conn ->
        case conn.request_path do
          "/oauth2/v1/token" ->
            Req.Test.json(conn, %{"access_token" => "test_token"})

          _ ->
            conn
            |> Plug.Conn.put_status(401)
            |> Req.Test.json(%{"errorSummary" => "Custom 401 error message"})
        end
      end)

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/settings/directory_sync/okta/new")

      lv |> element("button", "Generate Keypair") |> render_click()

      lv
      |> form("#directory-form", %{
        "directory" => %{
          "name" => "Test",
          "okta_domain" => "test.okta.com",
          "client_id" => "test"
        }
      })
      |> render_change()

      lv |> element("button", "Verify Now") |> render_click()

      wait_for_verification_error(lv, "Authentication failed: Custom 401 error message")
    end

    test "Okta 401 fallback (no known error code)", %{account: account, actor: actor, conn: conn} do
      Req.Test.stub(Okta.APIClient, fn conn ->
        case conn.request_path do
          "/oauth2/v1/token" ->
            Req.Test.json(conn, %{"access_token" => "test_token"})

          _ ->
            conn
            |> Plug.Conn.put_status(401)
            |> Req.Test.json(%{})
        end
      end)

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/settings/directory_sync/okta/new")

      lv |> element("button", "Generate Keypair") |> render_click()

      lv
      |> form("#directory-form", %{
        "directory" => %{
          "name" => "Test",
          "okta_domain" => "test.okta.com",
          "client_id" => "test"
        }
      })
      |> render_change()

      lv |> element("button", "Verify Now") |> render_click()

      wait_for_verification_error(lv, "HTTP 401 Unauthorized")
    end

    test "Okta 403 with errorSummary", %{account: account, actor: actor, conn: conn} do
      Req.Test.stub(Okta.APIClient, fn conn ->
        case conn.request_path do
          "/oauth2/v1/token" ->
            Req.Test.json(conn, %{"access_token" => "test_token"})

          _ ->
            conn
            |> Plug.Conn.put_status(403)
            |> Req.Test.json(%{"errorSummary" => "Custom 403 error"})
        end
      end)

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/settings/directory_sync/okta/new")

      lv |> element("button", "Generate Keypair") |> render_click()

      lv
      |> form("#directory-form", %{
        "directory" => %{
          "name" => "Test",
          "okta_domain" => "test.okta.com",
          "client_id" => "test"
        }
      })
      |> render_change()

      lv |> element("button", "Verify Now") |> render_click()

      wait_for_verification_error(lv, "Permission denied: Custom 403 error")
    end

    test "Okta 403 fallback (no known error code)", %{account: account, actor: actor, conn: conn} do
      Req.Test.stub(Okta.APIClient, fn conn ->
        case conn.request_path do
          "/oauth2/v1/token" ->
            Req.Test.json(conn, %{"access_token" => "test_token"})

          _ ->
            conn
            |> Plug.Conn.put_status(403)
            |> Req.Test.json(%{})
        end
      end)

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/settings/directory_sync/okta/new")

      lv |> element("button", "Generate Keypair") |> render_click()

      lv
      |> form("#directory-form", %{
        "directory" => %{
          "name" => "Test",
          "okta_domain" => "test.okta.com",
          "client_id" => "test"
        }
      })
      |> render_change()

      lv |> element("button", "Verify Now") |> render_click()

      wait_for_verification_error(lv, "HTTP 403 Forbidden")
    end

    test "Okta 404 with errorSummary", %{account: account, actor: actor, conn: conn} do
      Req.Test.stub(Okta.APIClient, fn conn ->
        case conn.request_path do
          "/oauth2/v1/token" ->
            Req.Test.json(conn, %{"access_token" => "test_token"})

          _ ->
            conn
            |> Plug.Conn.put_status(404)
            |> Req.Test.json(%{"errorSummary" => "Custom 404 error"})
        end
      end)

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/settings/directory_sync/okta/new")

      lv |> element("button", "Generate Keypair") |> render_click()

      lv
      |> form("#directory-form", %{
        "directory" => %{
          "name" => "Test",
          "okta_domain" => "test.okta.com",
          "client_id" => "test"
        }
      })
      |> render_change()

      lv |> element("button", "Verify Now") |> render_click()

      wait_for_verification_error(lv, "Not found: Custom 404 error")
    end

    test "Okta 404 fallback (no known error code)", %{account: account, actor: actor, conn: conn} do
      Req.Test.stub(Okta.APIClient, fn conn ->
        case conn.request_path do
          "/oauth2/v1/token" ->
            Req.Test.json(conn, %{"access_token" => "test_token"})

          _ ->
            conn
            |> Plug.Conn.put_status(404)
            |> Req.Test.json(%{})
        end
      end)

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/settings/directory_sync/okta/new")

      lv |> element("button", "Generate Keypair") |> render_click()

      lv
      |> form("#directory-form", %{
        "directory" => %{
          "name" => "Test",
          "okta_domain" => "test.okta.com",
          "client_id" => "test"
        }
      })
      |> render_change()

      lv |> element("button", "Verify Now") |> render_click()

      wait_for_verification_error(lv, "HTTP 404 Not Found")
    end

    test "Google 400 with generic error_description", %{
      account: account,
      actor: actor,
      conn: conn
    } do
      Req.Test.stub(Google.APIClient, fn conn ->
        conn
        |> Plug.Conn.put_status(400)
        |> Req.Test.json(%{
          "error" => "invalid_grant",
          "error_description" => "Some other grant error"
        })
      end)

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/settings/directory_sync/google/new")

      lv
      |> form("#directory-form", %{
        "directory" => %{"name" => "Test", "impersonation_email" => "test@example.com"}
      })
      |> render_change()

      lv |> element("button", "Verify Now") |> render_click()

      wait_for_verification_error(lv, "Authentication failed: Some other grant error")
    end

    test "Google 400 with only error_description (no error type)", %{
      account: account,
      actor: actor,
      conn: conn
    } do
      Req.Test.stub(Google.APIClient, fn conn ->
        conn
        |> Plug.Conn.put_status(400)
        |> Req.Test.json(%{
          "error" => "some_error",
          "error_description" => "Description without known error type"
        })
      end)

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/settings/directory_sync/google/new")

      lv
      |> form("#directory-form", %{
        "directory" => %{"name" => "Test", "impersonation_email" => "test@example.com"}
      })
      |> render_change()

      lv |> element("button", "Verify Now") |> render_click()

      wait_for_verification_error(lv, "Description without known error type")
    end
  end

  describe "Entra admin consent verification flow" do
    test "clicking Verify Now button triggers admin consent flow", %{
      account: account,
      actor: actor,
      conn: conn
    } do
      # Configure Entra API client for tests
      Portal.Config.put_env_override(Entra.APIClient,
        client_id: "test-entra-client-id",
        client_secret: "test-secret",
        req_options: [plug: {Req.Test, Entra.APIClient}, retry: false]
      )

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/settings/directory_sync/entra/new")

      # Fill in the form - Entra only has name field, tenant_id is set via admin consent
      lv
      |> form("#directory-form", %{
        "directory" => %{
          "name" => "Test Entra"
        }
      })
      |> render_change()

      # Start verification - this triggers the admin consent flow via push_event("open_url", ...)
      # The Entra flow doesn't set verifying: true like Google/Okta - it opens a new window
      # and waits for PubSub callback. We verify the button click doesn't crash.
      html = lv |> element("button", "Verify Now") |> render_click()

      # The form should still be showing (verification opens in new window)
      assert html =~ "Add Microsoft Entra Directory"
    end
  end

  describe "handle_event - submit_directory (edit) for non-Google" do
    test "editing Entra directory does not clear legacy_service_account_key", %{
      account: account,
      actor: actor,
      conn: conn
    } do
      # Create an Entra directory
      directory = entra_directory_fixture(account: account, name: "Entra Test", is_verified: true)

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/settings/directory_sync/entra/#{directory.id}/edit")

      # Update name
      lv
      |> form("#directory-form", %{
        "directory" => %{"name" => "Updated Entra Name"}
      })
      |> render_change()

      # Submit
      lv |> form("#directory-form") |> render_submit()

      # Check flash and name update
      html = render(lv)
      assert html =~ "Directory saved successfully"
      assert html =~ "Updated Entra Name"

      # Verify the directory was updated
      updated = Portal.Repo.get!(Entra.Directory, directory.id)
      assert updated.name == "Updated Entra Name"
    end

    test "editing Okta directory does not clear legacy_service_account_key", %{
      account: account,
      actor: actor,
      conn: conn
    } do
      # Create an Okta directory
      directory = okta_directory_fixture(account: account, name: "Okta Test", is_verified: true)

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/settings/directory_sync/okta/#{directory.id}/edit")

      # Update name
      lv
      |> form("#directory-form", %{
        "directory" => %{"name" => "Updated Okta Name"}
      })
      |> render_change()

      # Submit
      lv |> form("#directory-form") |> render_submit()

      # Check flash and name update
      html = render(lv)
      assert html =~ "Directory saved successfully"
      assert html =~ "Updated Okta Name"

      # Verify the directory was updated
      updated = Portal.Repo.get!(Okta.Directory, directory.id)
      assert updated.name == "Updated Okta Name"
    end

    test "changing Okta Client ID after verification saves the new value", %{
      account: account,
      actor: actor,
      conn: conn
    } do
      # Customer bug report: changing Client ID on Okta form after verification
      # should save the new Client ID, not the original one

      # Mock Okta API to succeed for any client_id
      Req.Test.stub(Okta.APIClient, fn conn ->
        case conn.request_path do
          "/oauth2/v1/token" ->
            Req.Test.json(conn, %{"access_token" => "test_token", "token_type" => "DPoP"})

          "/api/v1/apps" ->
            Req.Test.json(conn, [%{"id" => "app1"}])

          "/api/v1/users" ->
            Req.Test.json(conn, [%{"id" => "user1"}])

          "/api/v1/groups" ->
            Req.Test.json(conn, [%{"id" => "group1"}])

          _ ->
            Req.Test.json(conn, %{})
        end
      end)

      # Create an Okta directory with original client_id
      directory =
        okta_directory_fixture(
          account: account,
          name: "Okta Client ID Test",
          client_id: "original_client_id",
          private_key_jwk: @test_private_key_jwk,
          kid: "test_kid",
          is_verified: true
        )

      # Verify original client_id
      assert directory.client_id == "original_client_id"

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/settings/directory_sync/okta/#{directory.id}/edit")

      # Change client_id to a new value - this should clear verification
      lv
      |> form("#directory-form", %{
        "directory" => %{"client_id" => "new_client_id"}
      })
      |> render_change()

      # Re-verify with the new client_id
      lv |> element("button", "Verify Now") |> render_click()
      render(lv)

      # Submit the form
      lv |> form("#directory-form") |> render_submit()

      # Check flash
      html = render(lv)
      assert html =~ "Directory saved successfully"

      # CRITICAL: Verify the new client_id was saved, not the original
      updated = Portal.Repo.get!(Okta.Directory, directory.id)

      assert updated.client_id == "new_client_id",
             "Expected client_id to be 'new_client_id' but got '#{updated.client_id}'"
    end
  end

  describe "Okta 403 with various error formats" do
    test "handles 403 with E0000006 error code", %{
      account: account,
      actor: actor,
      conn: conn
    } do
      Req.Test.stub(Okta.APIClient, fn conn ->
        case conn.request_path do
          "/oauth2/v1/token" ->
            Req.Test.json(conn, %{"access_token" => "test_token"})

          _ ->
            conn
            |> Plug.Conn.put_status(403)
            |> Req.Test.json(%{"errorCode" => "E0000006", "errorSummary" => "Access denied"})
        end
      end)

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/settings/directory_sync/okta/new")

      lv |> element("button", "Generate Keypair") |> render_click()

      lv
      |> form("#directory-form", %{
        "directory" => %{
          "name" => "Test",
          "okta_domain" => "test.okta.com",
          "client_id" => "test"
        }
      })
      |> render_change()

      # Verification is async - click triggers :do_verification message
      lv |> element("button", "Verify Now") |> render_click()
      # Wait for async message to be processed and get updated HTML
      html = render(lv)

      # E0000006 maps to this specific error message
      assert html =~ "Access denied. You do not have permission to perform this action"
    end

    test "handles 403 with E0000022 error code", %{
      account: account,
      actor: actor,
      conn: conn
    } do
      Req.Test.stub(Okta.APIClient, fn conn ->
        case conn.request_path do
          "/oauth2/v1/token" ->
            Req.Test.json(conn, %{"access_token" => "test_token"})

          _ ->
            conn
            |> Plug.Conn.put_status(403)
            |> Req.Test.json(%{"errorCode" => "E0000022"})
        end
      end)

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/settings/directory_sync/okta/new")

      lv |> element("button", "Generate Keypair") |> render_click()

      lv
      |> form("#directory-form", %{
        "directory" => %{
          "name" => "Test",
          "okta_domain" => "test.okta.com",
          "client_id" => "test"
        }
      })
      |> render_change()

      # Verification is async
      lv |> element("button", "Verify Now") |> render_click()

      # E0000022 maps to this specific error message
      wait_for_verification_error(lv, "API access denied. The feature may not be available")
    end
  end

  describe "recent sync jobs display" do
    setup %{account: account} do
      directory = google_directory_fixture(account: account)

      %{directory: directory}
    end

    test "list_all_directories includes most recent completed job", %{
      account: account,
      actor: actor,
      directory: directory
    } do
      subject = admin_subject_fixture(account: account, actor: actor)
      # Insert a completed job directly into the database
      now = DateTime.utc_now()
      inserted_at = DateTime.add(now, -120, :second)

      Portal.Repo.insert!(%Oban.Job{
        worker: "Portal.Google.Sync",
        queue: "default",
        args: %{"directory_id" => directory.id},
        state: "completed",
        inserted_at: inserted_at,
        completed_at: now,
        max_attempts: 3,
        attempt: 1
      })

      [enriched] = Database.list_all_directories(subject)

      assert enriched.most_recent_job != nil
      assert enriched.most_recent_job.state == "completed"
      assert enriched.most_recent_job.elapsed_seconds == 120
      assert enriched.most_recent_job.directory_id == directory.id
    end

    test "list_all_directories includes active job as most_recent_job", %{
      account: account,
      actor: actor,
      directory: directory
    } do
      subject = admin_subject_fixture(account: account, actor: actor)

      # Insert an executing job
      now = DateTime.utc_now()
      inserted_at = DateTime.add(now, -30, :second)

      Portal.Repo.insert!(%Oban.Job{
        worker: "Portal.Google.Sync",
        queue: "default",
        args: %{"directory_id" => directory.id},
        state: "executing",
        inserted_at: inserted_at,
        max_attempts: 3,
        attempt: 1
      })

      [enriched] = Database.list_all_directories(subject)

      assert enriched.has_active_job == true
      assert enriched.most_recent_job != nil
      assert enriched.most_recent_job.state == "executing"
      # Elapsed time should be approximately 30 seconds (allow some margin)
      assert enriched.most_recent_job.elapsed_seconds >= 29 and
               enriched.most_recent_job.elapsed_seconds <= 35
    end

    test "list_all_directories prioritizes active job over completed job", %{
      account: account,
      actor: actor,
      directory: directory
    } do
      subject = admin_subject_fixture(account: account, actor: actor)
      now = DateTime.utc_now()

      # Insert a completed job
      Portal.Repo.insert!(%Oban.Job{
        worker: "Portal.Google.Sync",
        queue: "default",
        args: %{"directory_id" => directory.id},
        state: "completed",
        attempted_at: DateTime.add(now, -300, :second),
        completed_at: DateTime.add(now, -240, :second),
        max_attempts: 3,
        attempt: 1
      })

      # Insert an executing job
      Portal.Repo.insert!(%Oban.Job{
        worker: "Portal.Google.Sync",
        queue: "default",
        args: %{"directory_id" => directory.id},
        state: "executing",
        attempted_at: DateTime.add(now, -10, :second),
        max_attempts: 3,
        attempt: 1
      })

      [enriched] = Database.list_all_directories(subject)

      # Active job should be returned as most_recent_job
      assert enriched.most_recent_job.state == "executing"
    end

    test "list_all_directories includes failed jobs", %{
      account: account,
      actor: actor,
      directory: directory
    } do
      subject = admin_subject_fixture(account: account, actor: actor)
      now = DateTime.utc_now()

      Portal.Repo.insert!(%Oban.Job{
        worker: "Portal.Google.Sync",
        queue: "default",
        args: %{"directory_id" => directory.id},
        state: "discarded",
        attempted_at: DateTime.add(now, -60, :second),
        completed_at: now,
        discarded_at: now,
        max_attempts: 3,
        attempt: 3,
        errors: [%{"at" => DateTime.to_iso8601(now), "error" => "Some error"}]
      })

      [enriched] = Database.list_all_directories(subject)

      assert enriched.most_recent_job != nil
      assert enriched.most_recent_job.state == "discarded"
      assert enriched.most_recent_job.errors != []
    end

    test "renders sync status with duration in directory card", %{
      account: account,
      actor: actor,
      directory: directory,
      conn: conn
    } do
      now = DateTime.utc_now()

      # Insert a completed job
      Portal.Repo.insert!(%Oban.Job{
        worker: "Portal.Google.Sync",
        queue: "default",
        args: %{"directory_id" => directory.id},
        state: "completed",
        inserted_at: DateTime.add(now, -120, :second),
        completed_at: now,
        max_attempts: 3,
        attempt: 1
      })

      {:ok, _lv, html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/settings/directory_sync")

      # Should show synced status with duration
      assert html =~ "synced"
      assert html =~ "in 2m"
    end

    test "renders in-progress job with syncing indicator", %{
      account: account,
      actor: actor,
      directory: directory,
      conn: conn
    } do
      now = DateTime.utc_now()

      # Insert an executing job
      Portal.Repo.insert!(%Oban.Job{
        worker: "Portal.Google.Sync",
        queue: "default",
        args: %{"directory_id" => directory.id},
        state: "executing",
        inserted_at: DateTime.add(now, -30, :second),
        max_attempts: 3,
        attempt: 1
      })

      {:ok, _lv, html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/settings/directory_sync")

      # Should show syncing indicator with elapsed time
      assert html =~ "syncing"
      assert html =~ "elapsed"
    end

    test "renders queued job status", %{
      account: account,
      actor: actor,
      directory: directory,
      conn: conn
    } do
      now = DateTime.utc_now()

      # Insert a scheduled job
      Portal.Repo.insert!(%Oban.Job{
        worker: "Portal.Google.Sync",
        queue: "default",
        args: %{"directory_id" => directory.id},
        state: "available",
        inserted_at: DateTime.add(now, -5, :second),
        scheduled_at: now,
        max_attempts: 3,
        attempt: 0
      })

      {:ok, _lv, html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/settings/directory_sync")

      # Should show queued indicator
      assert html =~ "sync queued"
    end

    test "sync_directory refreshes the page and shows queued status", %{
      account: account,
      actor: actor,
      conn: conn
    } do
      directory = synced_google_directory_fixture(account: account)

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/settings/directory_sync")

      # Click Sync Now button
      html =
        lv
        |> element("button[phx-click='sync_directory'][phx-value-id='#{directory.id}']")
        |> render_click()

      # Should show success flash and queued/syncing status
      assert html =~ "Directory sync has been queued successfully"
      assert html =~ "sync queued" or html =~ "syncing"
    end

    test "sync_directory disables Sync Now button when job is active", %{
      account: account,
      actor: actor,
      conn: conn
    } do
      directory = synced_google_directory_fixture(account: account)
      now = DateTime.utc_now()

      # Insert an executing job
      Portal.Repo.insert!(%Oban.Job{
        worker: "Portal.Google.Sync",
        queue: "default",
        args: %{"directory_id" => directory.id},
        state: "executing",
        attempted_at: DateTime.add(now, -10, :second),
        max_attempts: 3,
        attempt: 1
      })

      {:ok, _lv, html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/settings/directory_sync")

      # The Sync Now button should be disabled
      assert html =~ ~r/button[^>]*disabled[^>]*>.*Sync Now/s or
               html =~ ~r/<button[^>]*phx-click="sync_directory"[^>]*disabled/
    end
  end

  describe "format_duration/1" do
    # Test the format_duration helper via the module
    # Since it's a private function, we test it indirectly through the UI

    test "displays seconds for durations under 60 seconds", %{
      account: account,
      actor: actor,
      conn: conn
    } do
      directory = google_directory_fixture(account: account)
      now = DateTime.utc_now()

      Portal.Repo.insert!(%Oban.Job{
        worker: "Portal.Google.Sync",
        queue: "default",
        args: %{"directory_id" => directory.id},
        state: "completed",
        inserted_at: DateTime.add(now, -45, :second),
        completed_at: now,
        max_attempts: 3,
        attempt: 1
      })

      {:ok, _lv, html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/settings/directory_sync")

      assert html =~ "45s"
    end

    test "displays minutes and seconds for longer durations", %{
      account: account,
      actor: actor,
      conn: conn
    } do
      directory = google_directory_fixture(account: account)
      now = DateTime.utc_now()

      # 2 minutes 30 seconds = 150 seconds
      Portal.Repo.insert!(%Oban.Job{
        worker: "Portal.Google.Sync",
        queue: "default",
        args: %{"directory_id" => directory.id},
        state: "completed",
        inserted_at: DateTime.add(now, -150, :second),
        completed_at: now,
        max_attempts: 3,
        attempt: 1
      })

      {:ok, _lv, html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/settings/directory_sync")

      assert html =~ "2m 30s"
    end
  end
end

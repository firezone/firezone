"use client";
import Collapse from "./Collapse";
import { useEffect } from "react";
import { initFlowbite } from "flowbite";
import Item from "./Item";
import SearchForm from "./SearchForm";
import { usePathname } from "next/navigation";

export default function KbSidebar() {
  const p = usePathname() || "";

  useEffect(() => {
    // Manually init flowbite's data-toggle listeners since we're using custom components
    initFlowbite();
  }, []);

  return (
    <aside
      id="kb-sidebar"
      aria-label="Sidebar"
      aria-hidden="true"
      className="sticky left-0 top-0 flex-none z-40 w-64 overflow-y-auto h-[calc(100vh)] pt-20 pb-8 transition-transform -translate-x-full bg-white border-r border-neutral-200 md:translate-x-0"
    >
      <SearchForm />
      <div className="mt-5 bg-white">
        <ul className="space-y-1 font-medium">
          <li>
            <Item topLevel href="/kb">
              Overview
            </Item>
          </li>
          <li>
            <Item topLevel href="/kb/quickstart">
              Quickstart
            </Item>
          </li>
          <li className="ml-3 pt-3 border-t border-neutral-200 uppercase font-bold text-neutral-800">
            Get started
          </li>
          <li>
            <Collapse expanded={p.startsWith("/kb/deploy")} label="Deploy">
              <li>
                <Item href="/kb/deploy">Overview</Item>
              </li>
              <li>
                <Item href="/kb/deploy/sites">Sites</Item>
              </li>
              <li>
                <Item href="/kb/deploy/gateways">Gateways</Item>
              </li>
              <li>
                <Item href="/kb/deploy/resources">Resources</Item>
              </li>
              <li>
                <Item href="/kb/deploy/groups">Groups</Item>
              </li>
              <li>
                <Item href="/kb/deploy/users">Users</Item>
              </li>
              <li>
                <Item href="/kb/deploy/policies">Policies</Item>
              </li>
              <li>
                <Item href="/kb/deploy/clients">Clients</Item>
              </li>
              <li>
                <Item href="/kb/deploy/dns">Configure DNS</Item>
              </li>
            </Collapse>
          </li>
          <li>
            <Collapse
              expanded={p.startsWith("/kb/authenticate")}
              label="Authenticate"
            >
              <li>
                <Item href="/kb/authenticate">Overview</Item>
              </li>
              <li>
                <Item href="/kb/authenticate/email">Email (OTP)</Item>
              </li>
              <li>
                <Item href="/kb/authenticate/google">
                  SSO with Google Workspace
                </Item>
              </li>
              <li>
                <Item href="/kb/authenticate/entra">SSO with Entra ID</Item>
              </li>
              <li>
                <Item href="/kb/authenticate/okta">SSO with Okta</Item>
              </li>
              <li>
                <Item href="/kb/authenticate/jumpcloud">
                  SSO with JumpCloud
                </Item>
              </li>
              <li>
                <Item href="/kb/authenticate/oidc">
                  SSO with Universal OIDC
                </Item>
              </li>
              <li>
                <Item nested href="/kb/authenticate/oidc/auth0">
                  Auth0
                </Item>
              </li>
              <li>
                <Item nested href="/kb/authenticate/oidc/fusion">
                  FusionAuth
                </Item>
              </li>
              <li>
                <Item href="/kb/authenticate/directory-sync">
                  Directory sync
                </Item>
              </li>
              <li>
                <Item href="/kb/authenticate/service-accounts">
                  Service accounts
                </Item>
              </li>
            </Collapse>
          </li>
          <li className="ml-3 pt-3 border-t border-neutral-200 uppercase font-bold text-neutral-800">
            Use Firezone
          </li>
          <li>
            <Collapse
              expanded={p.startsWith("/kb/administer")}
              label="Administer"
            >
              <li>
                <Item href="/kb/administer">Overview</Item>
              </li>
              <li>
                <Item href="/kb/administer/upgrading">Upgrade Gateways</Item>
              </li>
              <li>
                <Item href="/kb/administer/backup-restore">
                  Backup & restore
                </Item>
              </li>
              <li>
                <Item href="/kb/administer/logs">Viewing logs</Item>
              </li>
              <li>
                <Item href="/kb/administer/troubleshooting">
                  Troubleshooting
                </Item>
              </li>
              <li>
                <Item href="/kb/administer/uninstall">Uninstall Firezone</Item>
              </li>
            </Collapse>
          </li>
          <li>
            <Collapse
              expanded={p.startsWith("/kb/user-guides")}
              label="End-user guides"
            >
              <li>
                <Item href="/kb/user-guides">Install Clients</Item>
              </li>
              <li>
                <Item nested href="/kb/user-guides/macos-client">
                  macOS
                </Item>
              </li>
              <li>
                <Item nested href="/kb/user-guides/ios-client">
                  iOS
                </Item>
              </li>
              <li>
                <Item nested href="/kb/user-guides/windows-client">
                  Windows
                </Item>
              </li>
              <li>
                <Item nested href="/kb/user-guides/android-client">
                  Android & ChromeOS
                </Item>
              </li>
              <li>
                <Item nested href="/kb/user-guides/linux-client">
                  Linux headless
                </Item>
              </li>
              <li>
                <Item nested href="/kb/user-guides/linux-gui-client">
                  Linux GUI
                </Item>
              </li>
            </Collapse>
          </li>
          <li>
            <Collapse
              expanded={p.startsWith("/kb/use-cases")}
              label="Use cases"
            >
              <li>
                <Item href="/kb/use-cases">Overview</Item>
              </li>
              <li>
                <Item href="/kb/use-cases/secure-dns">Block malicious DNS</Item>
              </li>
              <li>
                <Item href="/kb/use-cases/scale-vpc-access">
                  Scale access to a VPC
                </Item>
              </li>
              <li>
                <Item href="/kb/use-cases/nat-gateway">
                  Route through a public IP
                </Item>
              </li>
              <li>
                <Item href="/kb/use-cases/postgres-access">
                  Access a Postgres DB
                </Item>
              </li>
              <li>
                <Item href="/kb/use-cases/saas-app-access">
                  Manage access to a SaaS app
                </Item>
              </li>
              <li>
                <Item href="/kb/use-cases/host-access">
                  Access a remote host
                </Item>
              </li>
              <li>
                <Item href="/kb/use-cases/private-network-access">
                  Access a private network
                </Item>
              </li>
              <li>
                <Item href="/kb/use-cases/web-app-access">
                  Access a private web app
                </Item>
              </li>
            </Collapse>
          </li>
          <li className="ml-3 pt-3 border-t border-neutral-200 uppercase font-bold text-neutral-800">
            Learn more
          </li>
          <li>
            <Collapse
              expanded={p.startsWith("/kb/architecture")}
              label="Architecture"
            >
              <li>
                <Item href="/kb/architecture">Overview</Item>
              </li>
              <li>
                <Item href="/kb/architecture/core-components">
                  Core components
                </Item>
              </li>
              <li>
                <Item href="/kb/architecture/tech-stack">Tech stack</Item>
              </li>
              <li>
                <Item href="/kb/architecture/critical-sequences">
                  Critical sequences
                </Item>
              </li>
              <li>
                <Item href="/kb/architecture/security-controls">
                  Security controls
                </Item>
              </li>
            </Collapse>
          </li>
          <li>
            <Collapse
              expanded={p.startsWith("/kb/reference")}
              label="Reference"
            >
              <li>
                <Item href="/kb/reference/faq">FAQ</Item>
              </li>
              <li>
                <Item href="/kb/reference/glossary">Glossary</Item>
              </li>
            </Collapse>
          </li>
        </ul>
      </div>
    </aside>
  );
}

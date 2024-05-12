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
      className="sticky left-0 top-0 flex-none z-40 w-64 overflow-y-auto h-[calc(100vh-20px)] pt-20 transition-transform -translate-x-full bg-white border-r border-neutral-200 md:translate-x-0"
    >
      <SearchForm />
      <div className="mt-5 bg-white">
        <ul className="space-y-2 font-medium">
          <li>
            <Item topLevel href="/kb" label="Overview" />
          </li>
          <li>
            <Item topLevel href="/kb/quickstart" label="Quickstart" />
          </li>
          <li className="ml-3 pt-3 border-t border-neutral-200 uppercase font-bold text-neutral-800">
            Get started
          </li>
          <li>
            <Collapse expanded={p.startsWith("/kb/deploy")} label="Deploy">
              <li>
                <Item href="/kb/deploy" label="Overview" />
              </li>
              <li>
                <Item href="/kb/deploy/sites" label="Sites" />
              </li>
              <li>
                <Item href="/kb/deploy/gateways" label="Gateways" />
              </li>
              <li>
                <Item href="/kb/deploy/resources" label="Resources" />
              </li>
              <li>
                <Item href="/kb/deploy/groups" label="Groups" />
              </li>
              <li>
                <Item href="/kb/deploy/users" label="Users" />
              </li>
              <li>
                <Item href="/kb/deploy/policies" label="Policies" />
              </li>
              <li>
                <Item href="/kb/deploy/clients" label="Distribute Clients" />
              </li>
              <li>
                <Item href="/kb/deploy/dns" label="Configure DNS" />
              </li>
            </Collapse>
          </li>
          <li>
            <Collapse
              expanded={p.startsWith("/kb/authenticate")}
              label="Authenticate"
            >
              <li>
                <Item href="/kb/authenticate" label="Overview" />
              </li>
              <li>
                <Item href="/kb/authenticate/email" label="Email (OTP)" />
              </li>
              <li>
                <Item href="/kb/authenticate/oidc" label="Universal OIDC" />
              </li>
              <li>
                <Item
                  nested
                  href="/kb/authenticate/oidc/fusion"
                  label="Fusion Auth"
                />
              </li>
              <li>
                <Item
                  href="/kb/authenticate/directory-sync"
                  label="SSO + directory sync"
                />
              </li>
              <li>
                <Item
                  nested
                  href="/kb/authenticate/google"
                  label="Google Workspace"
                />
              </li>
              <li>
                <Item
                  nested
                  href="/kb/authenticate/entra"
                  label="Microsoft Entra ID"
                />
              </li>
              <li>
                <Item nested href="/kb/authenticate/okta" label="Okta" />
              </li>
              <li>
                <Item
                  href="/kb/authenticate/service-accounts"
                  label="Service accounts"
                />
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
                <Item href="/kb/administer" label="Overview" />
              </li>
              <li>
                <Item
                  href="/kb/administer/upgrading"
                  label="Upgrading Gateways"
                />
              </li>
              <li>
                <Item
                  href="/kb/administer/backup-restore"
                  label="Backup and restore"
                />
              </li>
              <li>
                <Item href="/kb/administer/logs" label="Viewing logs" />
              </li>
              <li>
                <Item
                  href="/kb/administer/troubleshooting"
                  label="Troubleshooting"
                />
              </li>
            </Collapse>
          </li>
          <li>
            <Collapse
              expanded={p.startsWith("/kb/user-guides")}
              label="End-user guides"
            >
              <li>
                <Item href="/kb/user-guides" label="Install Clients" />
              </li>
              <li>
                <Item
                  nested
                  href="/kb/user-guides/macos-client"
                  label="macOS"
                />
              </li>
              <li>
                <Item nested href="/kb/user-guides/ios-client" label="iOS" />
              </li>
              <li>
                <Item
                  nested
                  href="/kb/user-guides/windows-client"
                  label="Windows"
                />
              </li>
              <li>
                <Item
                  nested
                  href="/kb/user-guides/android-client"
                  label="Android & ChromeOS"
                />
              </li>
              <li>
                <Item
                  nested
                  href="/kb/user-guides/linux-client"
                  label="Linux"
                />
              </li>
            </Collapse>
          </li>
          <li>
            <Collapse
              expanded={p.startsWith("/kb/use-cases")}
              label="Use cases"
            >
              <li>
                <Item href="/kb/use-cases" label="Overview" />
              </li>
              <li>
                <Item
                  href="/kb/use-cases/secure-dns"
                  label="Block malicious DNS"
                />
              </li>
              <li>
                <Item
                  href="/kb/use-cases/scale-vpc-access"
                  label="Scale access to a VPC"
                />
              </li>
              <li>
                <Item
                  href="/kb/use-cases/nat-gateway"
                  label="Route through a public IP"
                />
              </li>
              <li>
                <Item
                  href="/kb/use-cases/postgres-access"
                  label="Access a Postgres DB"
                />
              </li>
              <li>
                <Item
                  href="/kb/use-cases/saas-app-access"
                  label="Manage access to a SaaS app"
                />
              </li>
              <li>
                <Item
                  href="/kb/use-cases/host-access"
                  label="Access a remote host"
                />
              </li>
              <li>
                <Item
                  href="/kb/use-cases/private-network-access"
                  label="Access a private network"
                />
              </li>
              <li>
                <Item
                  href="/kb/use-cases/web-app-access"
                  label="Access a private web app"
                />
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
                <Item href="/kb/architecture" label="Overview" />
              </li>
              <li>
                <Item
                  href="/kb/architecture/core-components"
                  label="Core components"
                />
              </li>
              <li>
                <Item href="/kb/architecture/tech-stack" label="Tech stack" />
              </li>
              <li>
                <Item
                  href="/kb/architecture/critical-sequences"
                  label="Critical sequences"
                />
              </li>
              <li>
                <Item
                  href="/kb/architecture/security-controls"
                  label="Security controls"
                />
              </li>
            </Collapse>
          </li>
          <li>
            <Collapse
              expanded={p.startsWith("/kb/reference")}
              label="Reference"
            >
              <li>
                <Item href="/kb/reference/faq" label="FAQ" />
              </li>
              <li>
                <Item href="/kb/reference/glossary" label="Glossary" />
              </li>
            </Collapse>
          </li>
        </ul>
      </div>
    </aside>
  );
}

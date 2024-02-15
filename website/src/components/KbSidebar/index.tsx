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
      className="sticky left-0 top-0 flex-none w-64 overflow-y-auto h-[calc(100vh-20px)] pt-20 transition-transform -translate-x-full bg-white border-r border-neutral-200 md:translate-x-0  "
    >
      <SearchForm />
      <div className="mt-5 bg-white pr-3">
        <ul className="space-y-2 font-medium">
          <li>
            <Item topLevel href="/kb" label="Overview" />
          </li>
          <li>
            <Item topLevel href="/kb/quickstart" label="Quickstart" />
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
                <Item href="/kb/deploy/policies" label="Policies" />
              </li>
              <li>
                <Item href="/kb/deploy/clients" label="Clients" />
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
                <Item href="/kb/authenticate/google" label="Google Workspace" />
              </li>
              <li>
                <Item
                  href="/kb/authenticate/entra"
                  label="Microsoft Entra ID"
                />
              </li>
              <li>
                <Item href="/kb/authenticate/okta" label="Okta" />
              </li>
              <li>
                <Item
                  href="/kb/authenticate/user-group-sync"
                  label="User / group sync"
                />
              </li>
              <li>
                <Item
                  href="/kb/authenticate/service-accounts"
                  label="Service accounts"
                />
              </li>
            </Collapse>
          </li>
          <li>
            <Collapse
              expanded={p.startsWith("/kb/administer")}
              label="Administer"
            >
              <li>
                <Item href="/kb/administer/upgrading" label="Upgrading" />
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
              label="User guides"
            >
              <li>
                <Item href="/kb/user-guides" label="Overview" />
              </li>
              <li>
                <Item
                  href="/kb/user-guides/apple-client"
                  label="macOS / iOS client"
                />
              </li>
              <li>
                <Item
                  href="/kb/user-guides/windows-client"
                  label="Windows client"
                />
              </li>
              <li>
                <Item
                  href="/kb/user-guides/android-client"
                  label="Android / ChromeOS client"
                />
              </li>
              <li>
                <Item
                  href="/kb/user-guides/linux-client"
                  label="Linux client"
                />
              </li>
            </Collapse>
          </li>
          <Collapse expanded={p.startsWith("/kb/reference")} label="Reference">
            <li>
              <Item href="/kb/reference/faq" label="FAQ" />
            </li>
            <li>
              <Item href="/kb/reference/glossary" label="Glossary" />
            </li>
          </Collapse>
        </ul>
      </div>
    </aside>
  );
}

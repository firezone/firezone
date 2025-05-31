import React from "react";
import logo from "../logo.png";
import { Session } from "./App";
import { Button } from "flowbite-react";

interface OverviewPageProps {
  session: Session | null;
  signOut: () => void;
  signIn: () => void;
}

export default function Overview({
  session,
  signOut,
  signIn,
}: OverviewPageProps) {
  return (
    <div className="flex flex-col items-center justify-center gap-4 min-h-screen">
      <img src={logo} alt="Firezone Logo" className="w-40 h-40" />

      <h1 className="text-6xl font-bold">Firezone</h1>

      {!session ? (
        <div id="signed-out">
          <div className="flex flex-col items-center gap-4">
            <p className="text-center">
              You can sign in by clicking the Firezone icon in the taskbar or by
              clicking 'Sign in' below.
            </p>
            <Button id="sign-in" onClick={signIn}>
              Sign in
            </Button>
            <p className="text-xs text-center">
              Firezone will continue running after this window is closed.
              <br />
              It is always available from the taskbar.
            </p>
          </div>
        </div>
      ) : (
        <div id="signed-in">
          <div className="flex flex-col items-center gap-4">
            <p className="text-center">
              You are currently signed into&nbsp;
              <span className="font-bold" id="account-slug">
                {session.account_slug}
              </span>
              &nbsp;as&nbsp;
              <span className="font-bold" id="actor-name">
                {session.actor_name}
              </span>
              .<br />
              Click the Firezone icon in the taskbar to see the list of
              Resources.
            </p>
            <Button id="sign-out" onClick={signOut}>
              Sign out
            </Button>
            <p className="text-xs text-center">
              Firezone will continue running in the taskbar after this window is
              closed.
            </p>
          </div>
        </div>
      )}
    </div>
  );
}

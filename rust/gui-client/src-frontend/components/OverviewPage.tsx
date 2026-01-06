import React from "react";
import logo from "../logo.png";
import { Button, Spinner } from "flowbite-react";
import { SessionViewModel } from "../generated/bindings";

interface OverviewPageProps {
  session: SessionViewModel | null;
  signOut: () => void;
  signIn: () => void;
}

export default function Overview(props: OverviewPageProps) {
  return (
    <div className="flex flex-col items-center justify-center gap-4">
      <img src={logo} alt="Firezone Logo" className="w-40 h-40" />

      <h1 className="text-6xl font-bold">Firezone</h1>

      <Session {...props} />
    </div>
  );
}

function Session(props: OverviewPageProps) {
  if (!props.session) {
    return <SignedOut {...props} />;
  }

  switch (props.session) {
    case "SignedOut": {
      return <SignedOut {...props} />;
    }
    case "Loading": {
      return <Loading />;
    }
    default: {
      const { account_slug, actor_name } = props.session.SignedIn;

      return (
        <SignedIn
          accountSlug={account_slug}
          actorName={actor_name}
          signOut={props.signOut}
        />
      );
    }
  }
}

interface SignedOutProps {
  signIn: () => void;
}

function SignedOut({ signIn }: SignedOutProps) {
  return (
    <div>
      <div className="flex flex-col items-center gap-4">
        <p className="text-center">
          You can sign in by clicking the Firezone icon in the taskbar or by
          clicking &quot;Sign in&quot; below.
        </p>
        <Button onClick={signIn}>Sign in</Button>
        <p className="text-xs text-center">
          Firezone will continue running after this window is closed.
          <br />
          It is always available from the taskbar.
        </p>
      </div>
    </div>
  );
}

interface SignedInProps {
  accountSlug: string;
  actorName: string;
  signOut: () => void;
}

function SignedIn({ actorName, accountSlug, signOut }: SignedInProps) {
  return (
    <div>
      <div className="flex flex-col items-center gap-4">
        <p className="text-center">
          You are currently signed into&nbsp;
          <span className="font-bold">{accountSlug}</span>
          &nbsp;as&nbsp;
          <span className="font-bold">{actorName}</span>
          .<br />
          Click the Firezone icon in the taskbar to see the list of Resources.
        </p>
        <Button onClick={signOut}>Sign out</Button>
        <p className="text-xs text-center">
          Firezone will continue running in the taskbar after this window is
          closed.
        </p>
      </div>
    </div>
  );
}

function Loading() {
  return (
    <div>
      <div className="flex flex-col items-center gap-4">
        <Spinner />
        <p className="text-xs text-center">
          Firezone will continue running in the taskbar after this window is
          closed.
        </p>
      </div>
    </div>
  );
}

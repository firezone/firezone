import React from "react";
import { SessionViewModel } from "../generated/bindings";
import logo from "../logo.png";
import Button from "./Button";

interface OverviewPageProps {
  session: SessionViewModel | null;
  signOut: () => void;
  signIn: () => void;
}

export default function Overview(props: OverviewPageProps) {
  return (
    <div className="flex min-h-full items-center justify-center bg-page p-6">
      <div className="flex w-full max-w-lg flex-col items-center gap-4 text-center">
        <img alt="Firezone Logo" className="h-20 w-20" src={logo} />
        <h1 className="text-xl font-semibold tracking-tight text-heading">
          Firezone
        </h1>
        <Session {...props} />
      </div>
    </div>
  );
}

function Session(props: OverviewPageProps) {
  if (!props.session) {
    return <SignedOut actorEmail={null} signIn={props.signIn} />;
  }

  if (props.session === "Loading") {
    return <Loading />;
  }

  if ("SignedOut" in props.session) {
    return (
      <SignedOut
        actorEmail={props.session.SignedOut.certificate_actor_email}
        signIn={props.signIn}
      />
    );
  }

  return (
    <SignedIn
      accountSlug={props.session.SignedIn.account_slug}
      actorName={props.session.SignedIn.actor_name}
      signOut={props.signOut}
      x509Authenticated={props.session.SignedIn.x509_authenticated}
    />
  );
}

interface SignedOutProps {
  actorEmail: string | null;
  signIn: () => void;
}

function SignedOut({ actorEmail, signIn }: SignedOutProps) {
  return (
    <div className="flex flex-col items-center gap-4">
      <p className="text-sm text-body">
        {actorEmail
          ? `Connect as ${actorEmail} to access Resources.`
          : "You can sign in by clicking the Firezone icon in the taskbar or by clicking “Sign in” below."}
      </p>
      <Button onClick={signIn} variant="primary">
        {actorEmail ? `Connect as ${actorEmail}` : "Sign in"}
      </Button>
      <p className="text-xs text-subtle">
        Firezone will continue running after this window is closed.
        <br />
        It is always available from the taskbar.
      </p>
    </div>
  );
}

interface SignedInProps {
  accountSlug: string;
  actorName: string;
  signOut: () => void;
  x509Authenticated: boolean;
}

function SignedIn({
  actorName,
  accountSlug,
  signOut,
  x509Authenticated,
}: SignedInProps) {
  return (
    <div className="flex flex-col items-center gap-4">
      <p className="text-sm text-body">
        You are currently {x509Authenticated ? "connected to" : "signed into"}
        &nbsp;
        <span className="font-bold text-heading">{accountSlug}</span>
        &nbsp;as&nbsp;
        <span className="font-bold text-heading">{actorName}</span>
        .<br />
        Click the Firezone icon in the taskbar to see the list of Resources.
      </p>
      <Button onClick={signOut} variant="primary">
        {x509Authenticated ? "Disconnect" : "Sign out"}
      </Button>
      <p className="text-xs text-subtle">
        Firezone will continue running in the taskbar after this window is
        closed.
      </p>
    </div>
  );
}

function Loading() {
  return (
    <div className="flex flex-col items-center gap-4">
      <span
        aria-label="Loading"
        className="h-5 w-5 animate-spin rounded-full border-2 border-brand-muted border-t-brand"
        role="status"
      />
      <p className="text-xs text-subtle">
        Firezone will continue running in the taskbar after this window is
        closed.
      </p>
    </div>
  );
}

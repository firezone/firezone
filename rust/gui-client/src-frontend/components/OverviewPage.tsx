import React from "react";
import { SessionViewModel, X509Identity } from "../generated/bindings";
import logo from "../logo.png";
import Button from "./Button";

interface OverviewPageProps {
  session: SessionViewModel | null;
  identity: X509Identity;
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
  if (!props.session || props.session === "SignedOut") {
    return <SignedOut identity={props.identity} signIn={props.signIn} />;
  }

  if (props.session === "Loading") {
    return <Loading />;
  }

  return (
    <SignedIn
      accountSlug={props.session.SignedIn.account_slug}
      actorName={props.session.SignedIn.actor_name}
      identity={props.identity}
      signOut={props.signOut}
    />
  );
}

interface SignedOutProps {
  identity: X509Identity;
  signIn: () => void;
}

const TOKEN_HINT =
  "You can sign in by clicking the Firezone icon in the taskbar or by " +
  "clicking the button below.";
const CERTIFICATE_HINT =
  "This device has a certificate Firezone presents to your account.";

// A certificate that claims an identity connects over mutual TLS, so the
// control says so and the browser is never opened.
function startSessionLabel(identity: X509Identity): string {
  if (identity === "Absent") {
    return "Sign in";
  }

  const { email } = identity.Claimed;

  return email === null ? "Connect" : `Connect as ${email}`;
}

function SignedOut({ identity, signIn }: SignedOutProps) {
  return (
    <div className="flex flex-col items-center gap-4">
      <p className="text-sm text-body">
        {identity === "Absent" ? TOKEN_HINT : CERTIFICATE_HINT}
      </p>
      <Button onClick={signIn} variant="primary">
        {startSessionLabel(identity)}
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
  identity: X509Identity;
  signOut: () => void;
}

function SignedIn({
  actorName,
  accountSlug,
  identity,
  signOut,
}: SignedInProps) {
  return (
    <div className="flex flex-col items-center gap-4">
      <p className="text-sm text-body">
        {identity === "Absent"
          ? "You are currently signed into"
          : "You are currently connected to"}
        &nbsp;
        <span className="font-bold text-heading">{accountSlug}</span>
        &nbsp;as&nbsp;
        <span className="font-bold text-heading">{actorName}</span>
        .<br />
        Click the Firezone icon in the taskbar to see the list of Resources.
      </p>
      <Button onClick={signOut} variant="primary">
        {identity === "Absent" ? "Sign out" : "Disconnect"}
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

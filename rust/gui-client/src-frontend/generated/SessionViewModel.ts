export type SessionViewModel =
    {
        SignedIn: {
            account_slug: string;
            actor_name: string
        }
    } |
    "Loading" |
    "SignedOut";

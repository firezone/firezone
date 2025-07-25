This is a [Next.js](https://nextjs.org) project bootstrapped with
[`create-next-app`](https://github.com/vercel/next.js/tree/canary/packages/create-next-app).

## Getting Started

First, install dependencies and populate the `timestamps.json` file:

```
pnpm setup
```

Next, create files `.env.local` and `.env.development.local` in this directory.

Put this in `.env.local`:

```
NEXT_PUBLIC_MIXPANEL_TOKEN=""
NEXT_PUBLIC_GOOGLE_ANALYTICS_ID=""
NEXT_PUBLIC_LINKEDIN_PARTNER_ID=""
FIREZONE_DEPLOYED_SHA=""
```

And this in `.env.development.local`:

```
# Created by Vercel CLI
EDGE_CONFIG=""
FIREZONE_DEPLOYED_SHA=""
SITE_URL=""
VERCEL_DEEP_CLONE=""
```

After that, make sure to contact the team for their values.

Then, run the development server:

```bash
npm run dev
# or
yarn dev
# or
pnpm dev
```

Open [http://localhost:3000](http://localhost:3000) with your browser to see the
result.

You can start editing the page by modifying `app/page.tsx`. The page
auto-updates as you edit the file.

### Linting

This project uses [biome](https://biomejs.dev) to format code and ensure a
consistent style. Use the [biome.json](../biome.json) in the root of
this repo to configure your editor.

## Learn More

To learn more about Next.js, take a look at the following resources:

- [Next.js Documentation](https://nextjs.org/docs) - learn about Next.js
  features and API.
- [Learn Next.js](https://nextjs.org/learn) - an interactive Next.js tutorial.

You can check out
[the Next.js GitHub repository](https://github.com/vercel/next.js) - your
feedback and contributions are welcome!

## Deploy on Vercel

The easiest way to deploy your Next.js app is to use the
[Vercel Platform](https://vercel.com/new?utm_medium=default-template&filter=next.js&utm_source=create-next-app&utm_campaign=create-next-app-readme)
from the creators of Next.js.

Check out our
[Next.js deployment documentation](https://nextjs.org/docs/deployment) for more
details.

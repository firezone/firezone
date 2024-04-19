import { connectBrowser, get_args, retryOrFail } from "./shared.ts";

(async (): Promise<void> => {
  const args = get_args();
  const browser = await connectBrowser(args);
  const page = await browser.newPage();

  await retryOrFail(async () => await page.goto(args.url), args.retries);

  await browser.disconnect();
  Deno.exit();
})();

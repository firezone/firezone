import { get_args, launchBrowser, retryOrFail } from "./shared.ts";

(async (): Promise<void> => {
  const args = get_args();
  const browser = await launchBrowser();
  const page = await browser.newPage();

  await retryOrFail(async () => await page.goto(args.url), args.retries);

  await browser.close();
  process.exit();
})();

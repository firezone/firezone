import { get_args, connectBrowser, retryOrFail } from './shared.js';


(async (): Promise<void> => {
  const args = get_args();
  const browser = await connectBrowser(args);
  const page = await browser.newPage();

  await retryOrFail(async () => await page.goto(args.url), args.retries);

  await browser.disconnect();
  process.exit();
})();

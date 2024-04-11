import { args, connectBrowser, exitOnLoadFailure } from './shared.js';


(async (): Promise<void> => {
  const browser = await connectBrowser();
  const page = await browser.newPage();

  const response = await page.goto(args.url);
  await exitOnLoadFailure(response);

  await browser.disconnect();
  process.exit();
})();

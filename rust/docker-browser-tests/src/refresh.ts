import { Browser, Page } from 'puppeteer';
import { connectBrowser, args, exitOnLoadFailure } from './shared.js';

async function activePage(browser: Browser): Promise<Page> {
  const pages = await browser.pages();
  if (pages.length !== 1) {
    throw new Error('Either no page found or more pages than expected found');
  }
  const page = pages[0];

  const pageUrl = new URL(page.url());
  const expectedUrl = new URL(args.url);
  if (pageUrl.origin !== expectedUrl.origin) {
    throw new Error('Expected page not found');
  }

  return page;
}

(async (): Promise<void> => {
  const browser = await connectBrowser();
  const page = await activePage(browser);

  const responseReload = await page.reload({ timeout: 2000 });
  await exitOnLoadFailure(responseReload)

  await browser.disconnect();
  process.exit()
})();

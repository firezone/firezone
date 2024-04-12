import { Browser, Page } from 'puppeteer';
import { connectBrowser, get_args, IArgs, retryOrFail } from './shared.js';

async function activePage(browser: Browser, args: IArgs): Promise<Page> {
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
  const args = get_args();
  const browser = await connectBrowser(args);
  const page = await activePage(browser, args);

  await retryOrFail(async () => await page.reload({ timeout: 2000 }), args.retries);

  await browser.disconnect();
  process.exit()
})();

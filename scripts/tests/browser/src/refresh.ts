import { Browser, Page, HTTPResponse } from 'puppeteer';
import { connectBrowser, args, exitOnLoadFailure } from './shared.js';

async function activePage(browser: Browser): Promise<Page | undefined> {
  const allPages = await browser.pages();
  for (let page of allPages) {
    const state = await page.evaluate(() => document.visibilityState);
    const pageUrl = new URL(page.url());
    const expectedUrl = new URL(args.url);
    if (state === 'visible' && pageUrl.origin === expectedUrl.origin) {
      return page;
    }
  }
}

const refreshPage = async (): Promise<void> => {
  const browser = await connectBrowser();
  const page = await activePage(browser);

  if (!page) {
    console.error('No active page found');
    process.exit(1);
  }

  const responseReload: HTTPResponse | null = await page.reload({ timeout: 2000 });
  await exitOnLoadFailure(responseReload)

  await browser.disconnect();
  process.exit()
};

refreshPage();

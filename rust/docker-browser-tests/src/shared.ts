import { parse } from 'ts-command-line-args';
import puppeteer, { Browser, HTTPResponse } from 'puppeteer';

interface IArgs {
  debugPort: number;
  url: string;
}

export const args = parse<IArgs>({
  debugPort: Number,
  url: String
});

export async function connectBrowser(): Promise<Browser> {
  return await puppeteer.connect({
    browserURL: `http://127.0.0.1:${args.debugPort}`,
  });
}

export async function exitOnLoadFailure(response: HTTPResponse | null): Promise<void> {
  const status: number | undefined = response?.status();

  if (status !== 200) {
    console.error(`Page load failed with status ${status}`);
    process.exit(1);
  } else {
    console.log('Success loading page');
  }
}

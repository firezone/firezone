import { parse } from 'ts-command-line-args';
import puppeteer, { Browser, HTTPResponse } from 'puppeteer';

export interface IArgs {
  debugPort: number;
  url: string;
  retries: number,
}

export function get_args(): IArgs {
  return parse<IArgs>({
    debugPort: Number,
    url: String,
    retries: Number
  });
}

export async function connectBrowser(args: IArgs): Promise<Browser> {
  return await puppeteer.connect({
    browserURL: `http://127.0.0.1:${args.debugPort}`,
  });
}

export async function retryOrFail(get_page: (() => Promise<HTTPResponse | null>), retries: number) {
  while (true) {
    try {
      const status: number | undefined = (await get_page())?.status();
      if (status !== 200) {
        throw Error(`Failed to load page with status ${status}`)
      }

      break;
    } catch (e) {
      if (retries === 0) {
        throw e;
      }
      retries--;
    }
  }
}


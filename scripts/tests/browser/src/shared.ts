import { parse } from "ts-command-line-args";
import puppeteer, { Browser, HTTPResponse } from "puppeteer";

export interface IArgs {
  url: string;
  retries: number;
}

export function get_args(): IArgs {
  return parse<IArgs>({
    url: String,
    retries: Number,
  });
}

export async function launchBrowser(): Promise<Browser> {
  return await puppeteer.launch({
    args: ["--disable-gpu --no-sandbox"],
  });
}

export async function retryOrFail(
  get_page: () => Promise<HTTPResponse | null>,
  retries: number
) {
  while (true) {
    try {
      const status: number | undefined = (await get_page())?.status();
      if (status !== 200) {
        throw Error(`Failed to load page with status ${status}`);
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

const puppeteer = require('puppeteer');
const util = require('util');

async function activePage(browser) {
  const allPages = await browser.pages();
  for(let page of allPages) {
    const state = await page.evaluate(() => document.visibilityState);
    if(state === 'visible') {
      return page;
    }
  } 
}
let refreshPage = async () => {
  const browser = await puppeteer.connect({
    browserURL: "http://127.0.0.1:9222",
  });

  const page = await activePage(browser);
  const responseReload = await page.reload();
  status = responseReload && responseReload.status(); 

  if(status !== 200){
    console.error(`Page reload failed with status ${status}`);
    process.exit(1);
  } else {
    console.log('Success');

    const bodyHandle = await page.evaluateHandle(() => document.body.innerHTML); 
    const html = await bodyHandle.jsonValue(); 
    console.log(html);
  }

  await browser.disconnect();
  console.log("disconnected")

  process.exit()
};

refreshPage();

const puppeteer = require('puppeteer');
const util = require('util');
const exec = util.promisify(require('child_process').exec);

// wrapper to use setTimeout with await
function timeout(ms) {
    return new Promise(resolve => setTimeout(resolve, ms));
}

let refreshPage = async () => {
  const browser = await puppeteer.launch({
    executablePath: "/usr/bin/chromium-browser",
    args: ["--no-sandbox"]
  });
  const page = await browser.newPage();

  // go to the page
  const response = await page.goto('http://dns.httpbin');
  let status = response && response.status();

  if(status !== 200){
    console.error(`Page load failed with status ${status}`);
    process.exit(1);
  } else {
    console.log('Success');
  }

  await timeout(120000);

  // Reload the page
  const responseReload = await page.reload();
  status = responseReload && responseReload.status(); 

  if(status !== 200){
    console.error(`Page reload failed with status ${status}`);
    process.exit(1);
  } else {
    console.log('Success');
  }

  await browser.close();
};

refreshPage();

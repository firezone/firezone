const puppeteer = require('puppeteer');

let launchPage = async () => {
  const browser = await puppeteer.connect({
    browserURL: "http://127.0.0.1:9222",
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
    const bodyHandle = await page.evaluateHandle(() => document.body.innerHTML); 
    const html = await bodyHandle.jsonValue(); 
    console.log(html);
  }

  await browser.disconnect();
  console.log("disconnected")

  process.exit()
};

launchPage();

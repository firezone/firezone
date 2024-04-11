"use strict";
var __awaiter = (this && this.__awaiter) || function (thisArg, _arguments, P, generator) {
    function adopt(value) { return value instanceof P ? value : new P(function (resolve) { resolve(value); }); }
    return new (P || (P = Promise))(function (resolve, reject) {
        function fulfilled(value) { try { step(generator.next(value)); } catch (e) { reject(e); } }
        function rejected(value) { try { step(generator["throw"](value)); } catch (e) { reject(e); } }
        function step(result) { result.done ? resolve(result.value) : adopt(result.value).then(fulfilled, rejected); }
        step((generator = generator.apply(thisArg, _arguments || [])).next());
    });
};
Object.defineProperty(exports, "__esModule", { value: true });
const shared_js_1 = require("./shared.js");
function activePage(browser) {
    return __awaiter(this, void 0, void 0, function* () {
        const allPages = yield browser.pages();
        for (let page of allPages) {
            const state = yield page.evaluate(() => document.visibilityState);
            const pageUrl = new URL(page.url());
            const expectedUrl = new URL(shared_js_1.args.url);
            if (state === 'visible' && pageUrl.origin === expectedUrl.origin) {
                return page;
            }
        }
    });
}
const refreshPage = () => __awaiter(void 0, void 0, void 0, function* () {
    const browser = yield (0, shared_js_1.connectBrowser)();
    const page = yield activePage(browser);
    if (!page) {
        console.error('No active page found');
        process.exit(1);
    }
    const responseReload = yield page.reload({ timeout: 2000 });
    yield (0, shared_js_1.exitOnLoadFailure)(responseReload);
    yield browser.disconnect();
    process.exit();
});
refreshPage();

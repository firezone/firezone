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
var __importDefault = (this && this.__importDefault) || function (mod) {
    return (mod && mod.__esModule) ? mod : { "default": mod };
};
Object.defineProperty(exports, "__esModule", { value: true });
exports.exitOnLoadFailure = exports.connectBrowser = exports.args = void 0;
const ts_command_line_args_1 = require("ts-command-line-args");
const puppeteer_1 = __importDefault(require("puppeteer"));
exports.args = (0, ts_command_line_args_1.parse)({
    debugPort: Number,
    url: String
});
function connectBrowser() {
    return __awaiter(this, void 0, void 0, function* () {
        return yield puppeteer_1.default.connect({
            browserURL: `http://127.0.0.1:${exports.args.debugPort}`,
        });
    });
}
exports.connectBrowser = connectBrowser;
function exitOnLoadFailure(response) {
    return __awaiter(this, void 0, void 0, function* () {
        const status = response === null || response === void 0 ? void 0 : response.status();
        if (status !== 200) {
            console.error(`Page load failed with status ${status}`);
            process.exit(1);
        }
        else {
            console.log('Success loading page');
        }
    });
}
exports.exitOnLoadFailure = exitOnLoadFailure;

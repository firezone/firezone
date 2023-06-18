const md5 = require("md5");

export default function gravatar(email: string, size?: number): string {
  const hash = md5(email);

  return `https://www.gravatar.com/avatar/${hash}` + (size ? `?s=${size}` : "");
}

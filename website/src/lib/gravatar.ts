const md5 = require("md5");

export default function gravatar(email: string): string {
  const hash = md5(email);
  return `https://www.gravatar.com/avatar/${hash}`;
}

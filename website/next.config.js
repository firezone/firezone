/** @type {import('next').NextConfig} */
const nextConfig = {
  experimental: {
    mdxRs: true,
  },
  images: {
    remotePatterns: [
      {
        hostname: "user-images.githubusercontent.com",
      },
    ],
  },
};

const withMDX = require("@next/mdx")();
module.exports = withMDX(nextConfig);

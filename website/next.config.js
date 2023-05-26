/** @type {import('next').NextConfig} */
const nextConfig = {
  images: {
    remotePatterns: [
      {
        hostname: 'user-images.githubusercontent.com'
      }
    ]
  }
}

module.exports = nextConfig

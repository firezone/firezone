const { config: prodConfig } = require('./prod')

module.exports.config = {
  ...prodConfig,
  minify: false,
  sourcemap: true,
  watch: true,
}
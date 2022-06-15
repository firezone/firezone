const { config: prodConfig } = require('./config.prod')

module.exports.config = {
  ...prodConfig,
  minify: false,
  sourcemap: true,
  watch: true,
}
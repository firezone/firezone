const esbuild = require('esbuild')
const { config } = require(`./${process.argv[2]}`)

esbuild.build(config).catch(() => process.exit(1))
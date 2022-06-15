const esbuild = require('esbuild')
const { config } = require(`./config.${process.argv[2]}`)

esbuild.build(config).catch(() => process.exit(1))
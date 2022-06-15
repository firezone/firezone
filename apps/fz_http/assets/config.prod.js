const path = require('path')
const { sassPlugin } = require('esbuild-sass-plugin')

const tildePlugin = {
  name: 'tilde',
  setup(build) {
    build.onResolve({ filter: /^~/ }, args => ({
      path: path.join(
        args.resolveDir,
        '..',
        args.path
          .replace(/^~/, 'node_modules/')
          .replace(/\?.*$|#\w+$/, '')
      ),
    }))
  },
}

module.exports.config = {
  entryPoints: ['js/admin.js', 'js/root.js', 'js/unprivileged.js'],
  bundle: true,
  outdir: '../priv/static/dist',
  publicPath: '/dist/',
  minify: true,
  plugins: [
    tildePlugin,
    sassPlugin({
      loadPaths: ['.'],
    })],
  loader: {
    '.eot': 'file',
    '.svg': 'file',
    '.ttf': 'file',
    '.woff': 'file',
    '.woff2': 'file',
  }
}

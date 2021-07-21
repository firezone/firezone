const path = require('path');
const glob = require('glob');
const MiniCssExtractPlugin = require('mini-css-extract-plugin');
const CssMinimizerPlugin = require('css-minimizer-webpack-plugin');
const CopyWebpackPlugin = require('copy-webpack-plugin');

module.exports = (env, options) => ({
  optimization: {
    minimizer: [
      '...',
      new CssMinimizerPlugin()
    ]
  },
  entry: {
    './js/app.js': glob.sync('./vendor/**/*.js').concat([
      // Local JS files to include in the bundle
      './js/hooks.js',
      './js/app.js',
      './node_modules/admin-one-bulma-dashboard/src/js/main.js'
    ])
  },
  output: {
    path: path.resolve(__dirname, '../priv/static/js'),
    filename: 'app.js',
    publicPath: '/js/'
  },
  module: {
    rules: [
      {
        test: /\.js$/,
        exclude: /node_modules/,
        use: {
          loader: 'babel-loader'
        }
      },
      {
        test: /\.[s]?css$/,
        use: [
          MiniCssExtractPlugin.loader,
          'css-loader',
          'sass-loader',
          'postcss-loader'
        ]
      },
      {
        test: /.(png|jpg|jpeg|gif|svg|woff|woff2|ttf|eot)$/,
        use: "url-loader?limit=100000"
      }
    ]
  },
  plugins: [
    new MiniCssExtractPlugin({ filename: '../css/app.css' }),
    new CopyWebpackPlugin({
      patterns: [
        { from: 'static/', to: '../' }
      ]
    })
  ]
});

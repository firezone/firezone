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
    'admin': glob.sync('./vendor/**/*.js').concat([
      // Local JS files to include in the bundle
      './js/admin.js',
      './node_modules/admin-one-bulma-dashboard/src/js/main.js'
    ]),
    'root': ['./js/root.js'],
    'unprivileged': ['./js/unprivileged.js']
  },
  output: {
    path: path.resolve(__dirname, '../priv/static/js'),
    filename: '[name].js',
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
        test: /.(png|jpg|jpeg|gif|svg|woff|woff2|ttf|eot|xml|webmanifest)$/,
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

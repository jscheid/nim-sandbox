var path = require('path');
var webpack = require('webpack');
var ExtractTextPlugin = require('extract-text-webpack-plugin');
var HtmlWebpackPlugin = require('html-webpack-plugin')

module.exports = {
  entry: {
    main: './src/index',
    worker: './src/worker',
  },
  output: {
    path: path.join(__dirname, 'dist', 'static'),
    filename: '[name]_[chunkhash].js',
    publicPath: '/static/'
  },
  plugins: [
    new ExtractTextPlugin('style_[chunkhash].css', { allChunks: true }),
    new webpack.optimize.OccurenceOrderPlugin(),
    new webpack.DefinePlugin({
      'process.env': {
        'NODE_ENV': JSON.stringify('production')
      }
    }),
    new webpack.optimize.UglifyJsPlugin({
      compressor: {
        warnings: false
      }
    }),
    new HtmlWebpackPlugin({
      title: 'Nim Sandbox',
      template: 'prod_index.html',
      favicon: 'static/favicon.ico',
      filename: '../index.html',
    }),
  ],
  resolve: {
    modulesDirectories: ['', 'node_modules'],
    extensions: [ '', '.js', '.jsx', '.css', '.scss'  ],
  },
  node: {
    fs: 'empty',
  },
  module: {
    loaders: [{
      test: /\.jsx?$/,
      loaders: ['babel'],
      include: path.join(__dirname, 'src'),
    }, {
      test: /\.css$/,
      loader: ExtractTextPlugin.extract('style', 'css!postcss'),
    }, {
      test: /\.scss$/,
      loader: ExtractTextPlugin.extract('style', 'css?modules&importLoaders=1&localIdentName=[name]__[local]___[hash:base64:5]!postcss!sass'),
    }]
  }
};

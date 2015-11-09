var path = require('path');
var webpack = require('webpack');
var ExtractTextPlugin = require('extract-text-webpack-plugin');

module.exports = {
  devtool: 'eval',
  entry: {
    main: [
      'webpack-hot-middleware/client',
      './src/index',
    ],
    worker: './src/worker',
  },
  output: {
    path: path.join(__dirname, 'dist'),
    filename: "[name].entry.js",
    publicPath: '/static/',
  },
  plugins: [
    new ExtractTextPlugin('style.css', { allChunks: true }),
    new webpack.HotModuleReplacementPlugin(),
    new webpack.NoErrorsPlugin(),
    new webpack.DefinePlugin({
      'ENVIRONMENT_IS_NODE': false,
    }),

    // new webpack.IgnorePlugin(/^node_modules\/webpack\/buildin\/module.js$/),
    // new webpack.IgnorePlugin(/^ws$/),

  ],
  resolve: {
    modulesDirectories: ['', 'node_modules'],
    extensions: [ '', '.js', '.jsx', '.css', '.scss'  ],
  },
  node: {
    fs: "empty"
  },
  module: {
    // noParse: [
    //   path.join(__dirname, "nim-compiler.js"),
    // ],
    loaders: [{
      test: /\.jsx?$/,
      loaders: ['babel'],
      include: path.join(__dirname, 'src'),
    }, {
      test: /\.css$/,
      loader: ExtractTextPlugin.extract('style', 'css?sourceMap!postcss'),
    }, {
      test: /\.scss$/,
      loader: ExtractTextPlugin.extract('style', 'css?sourceMap&modules&importLoaders=1&localIdentName=[name]__[local]___[hash:base64:5]!postcss!sass?sourceMap'),
    }]
  }
};

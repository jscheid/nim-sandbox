const sourceFilename = 'main.nim';

const nimCompiler = {};

/**
 * Converts an array buffer to a string
 *
 * @private
 * @param {ArrayBuffer} buf The buffer to convert
 * @param {Function} callback The function to call when conversion is complete
 */
function ab2str(buf) {
  return decodeURIComponent(escape(String.fromCharCode.apply(null, buf)));
}

function str2ab(s) {
  const str = unescape(encodeURIComponent(s))
  const uint = new Uint8Array(str.length);
  for (let i = 0, j = str.length ; i < j; ++i) {
    uint[i] = str.charCodeAt(i);
  }
  return uint;
}

function writeSource(str) {
  const data = str2ab(str);
  const stream = nimCompiler.FS.open(sourceFilename, 'w');
  nimCompiler.FS.write(stream, data, 0, data.length, 0);
  nimCompiler.FS.close(stream);
}

nimCompiler.noInitialRun = true;
nimCompiler.print = text => console.log('stdout: ' + text);
nimCompiler.printErr = text => console.log('stderr: ' + text);
nimCompiler.TOTAL_MEMORY = 16777216 * 4;
nimCompiler.onRuntimeInitialized = () => {
  writeSource('');

  nimCompiler.callMain(['js', sourceFilename]);
  const recompile = nimCompiler.cwrap('recompile', null, ['string'])

  onmessage = event => {
    writeSource(event.data.source);
    const cmd = ['js', '-f' ].concat(event.data.flags).concat([ sourceFilename ]).join(' ');
    try {
      recompile(cmd);
    } catch (e) {
      console.warn(e);
    }

    const data = ab2str(nimCompiler.FS.lookupPath('/nimcache/main.js', {}).node.contents);
    postMessage({
      type: 'compilation',
      data,
    });
  };

  postMessage({
    type: 'startup',
    data: 1.0,
  })

  nimCompiler.printErr = text => postMessage({
    type: 'stderr',
    data: text,
  });
};

const initNimCompiler = require('exports?NimCompiler!../nim-compiler.js');
initNimCompiler(nimCompiler);

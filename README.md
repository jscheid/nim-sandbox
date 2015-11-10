# Nim Sandbox

A quick hack for experimenting with Nim in the browser: https://jscheid.github.io/nim-sandbox/index.html

## Status

* GC issues, workaround as per https://github.com/nim-lang/Nim/pull/3314#issuecomment-142563072

* Memory overflow after a couple of compiles (or presumably, during the first compile of a large project)

* Various usability issues
  * No error display in code editor
  * Run doesn't auto-compile
  * No load or save

* Probably many others, this is barely tested. If it breaks, you get to keep all the shiny pieces!

* No tests

## Build

* Install Node.js and Emscripten SDK, set up env
* `npm install`
* `npm start` to run the development server
* `npm run build` to create the distribution

## License

MIT

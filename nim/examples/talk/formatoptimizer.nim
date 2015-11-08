## This is the example that optimizes a modified "hello world"

import macros

proc invalidFormatString() =
  echo "invalidFormatString"

template formatImpl(handleChar: expr) =
  var i = 0
  while i < f.len:
    if f[i] == '$':
      case f[i+1]
      of '1'..'9':
        var j = 0
        i += 1
        while f[i] in {'0'..'9'}:
          j = j * 10 + ord(f[i]) - ord('0')
          i += 1
        result.add(a[j-1])
      else:
        invalidFormatString()
    else:
      result.add(handleChar(f[i]))
      i += 1

proc `%`*(f: string, a: openArray[string]): string =
  template identity(x: expr): expr = x
  result = ""
  formatImpl(identity)

macro optFormat{`%`(f, a)}(f: string{lit}, a: openArray[string]): expr =
  result = newNimNode(nnkBracket)
  #newCall("&")
  let f = f.strVal
  formatImpl(newLit)
  result = nestList(!"&", result)

template optAdd1{x = y; add(x, z)}(x, y, z: string) =
  x = y & z

#template optAdd2{x.add(y); x.add(z)}(x, y, z: string) =
#  x.add(y & z)

proc `/&` [T: object](x: T): string =
  result = "("
  for name, value in fieldPairs(x):
    result.add("$1: $2\n" % [name, $value])
  result.add(")")

type
  MyObject = object
    a, b: int
    s: string
let obj = MyObject(a: 3, b: 4, s: "abc")
echo(/&obj)

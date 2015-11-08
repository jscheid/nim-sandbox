discard """
  output: "works"
"""

import cgi, strtabs

proc handleRequest(query: string): StringTableRef =
  iterator foo(): StringTableRef {.closure.} =
    var params = {:}.newStringTable()
    for key, val in cgi.decodeData(query):
      params[key] = val
    yield params

  let x = foo
  result = x()

const Limit = when compileOption("gc", "markAndSweep"): 5*1024*1024 else: 700_000

proc main =
  var counter = 0
  for i in 0 .. 100_000:
    for k, v in handleRequest("nick=Elina2&type=activate"):
      inc counter
      if counter mod 100 == 0:
        if getOccupiedMem() > Limit:
          quit "but now a leak"

main()
echo "works"

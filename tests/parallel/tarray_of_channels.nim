# bug #2257
import threadpool

type StringChannel = TChannel[string]
var channels: array[1..3, StringChannel]

type
  MyObject[T] = object
    x: T

var global: MyObject[string]
var globalB: MyObject[float]

proc consumer(ix : int) {.thread.} =
  echo channels[ix].recv() ###### not GC-safe: 'channels'
  echo globalB

proc main =
  for ix in 1..3: channels[ix].open()
  for ix in 1..3: spawn consumer(ix)
  for ix in 1..3: channels[ix].send("test")
  sync()
  for ix in 1..3: channels[ix].close()

when isMainModule:
  main()

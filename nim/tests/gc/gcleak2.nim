discard """
  outputsub: "no leak: "
"""

when defined(GC_setMaxPause):
  GC_setMaxPause 2_000

type
  TTestObj = object of TObject
    x: string
    s: seq[int]

proc MakeObj(): TTestObj =
  result.x = "Hello"
  result.s = @[1,2,3]

proc inProc() =
  for i in 1 .. 1_000_000:
    when defined(gcMarkAndSweep):
      GC_fullcollect()
    var obj: TTestObj
    obj = MakeObj()
    if getOccupiedMem() > 300_000: quit("still a leak!")

inProc()
echo "no leak: ", getOccupiedMem()



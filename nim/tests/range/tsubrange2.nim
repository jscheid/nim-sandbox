discard """
  file: "tsubrange2.nim"
  outputsub: "value out of range: 50 [RangeError]"
  exitcode: "1"
"""

type
  TRange = range[0..40]

proc p(r: TRange) =
  discard

var
  r: TRange
  y = 50
p y


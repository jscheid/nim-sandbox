discard """
  msg: "Warning: 'y' might not have been initialized [Uninit]"
  line:34
"""

import strutils

{.warning[Uninit]:on.}

proc p =
  var x, y, z: int
  if stdin.readLine == "true":
    x = 34

    while false:
      y = 999
      break

    while true:
      if x == 12: break
      y = 9999

    try:
      z = parseInt("1233")
    except E_Base:
      case x
      of 34: z = 123
      of 13: z = 34
      else: z = 8
  else:
    y = 3444
    x = 3111
    z = 0
  echo x, y, z

p()

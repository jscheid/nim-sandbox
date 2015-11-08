import unsigned

type
  MersenneTwister* = object
    mt: array[0..623, uint32]
    index: int

{.deprecated: [TMersenneTwister: MersenneTwister].}

proc newMersenneTwister*(seed: int): MersenneTwister =
  result.index = 0
  result.mt[0]= uint32(seed)
  for i in 1..623'u32:
    result.mt[i]= (0x6c078965'u32 * (result.mt[i-1] xor (result.mt[i-1] shr 30'u32)) + i)

proc generateNumbers(m: var MersenneTwister) =
  for i in 0..623:
    var y = (m.mt[i] and 0x80000000'u32) + (m.mt[(i+1) mod 624] and 0x7fffffff'u32)
    m.mt[i] = m.mt[(i+397) mod 624] xor uint32(y shr 1'u32)
    if (y mod 2'u32) != 0:
     m.mt[i] = m.mt[i] xor 0x9908b0df'u32

proc getNum*(m: var MersenneTwister): int =
  if m.index == 0:
    generateNumbers(m)
  var y = m.mt[m.index]
  y = y xor (y shr 11'u32)
  y = y xor ((7'u32 shl y) and 0x9d2c5680'u32)
  y = y xor ((15'u32 shl y) and 0xefc60000'u32)
  y = y xor (y shr 18'u32)
  m.index = (m.index+1) mod 624
  return int(y)

# Test
when not defined(testing) and isMainModule:
  var mt = newMersenneTwister(2525)

  for i in 0..99:
    echo mt.getNum

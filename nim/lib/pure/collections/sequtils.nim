#
#
#            Nim's Runtime Library
#        (c) Copyright 2011 Alexander Mitchell-Robinson
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.
#

## :Author: Alexander Mitchell-Robinson (Amrykid)
##
## This module implements operations for the built-in `seq`:idx: type which
## were inspired by functional programming languages. If you are looking for
## the typical `map` function which applies a function to every element in a
## sequence, it already exists in the `system <system.html>`_ module in both
## mutable and immutable styles.
##
## Also, for functional style programming you may want to pass `anonymous procs
## <manual.html#anonymous-procs>`_ to procs like ``filter`` to reduce typing.
## Anonymous procs can use `the special do notation <manual.html#do-notation>`_
## which is more convenient in certain situations.
##
## **Note**: This interface will change as soon as the compiler supports
## closures and proper coroutines.

when not defined(nimhygiene):
  {.pragma: dirty.}

proc concat*[T](seqs: varargs[seq[T]]): seq[T] =
  ## Takes several sequences' items and returns them inside a new sequence.
  ##
  ## Example:
  ##
  ## .. code-block::
  ##   let
  ##     s1 = @[1, 2, 3]
  ##     s2 = @[4, 5]
  ##     s3 = @[6, 7]
  ##     total = concat(s1, s2, s3)
  ##   assert total == @[1, 2, 3, 4, 5, 6, 7]
  var L = 0
  for seqitm in items(seqs): inc(L, len(seqitm))
  newSeq(result, L)
  var i = 0
  for s in items(seqs):
    for itm in items(s):
      result[i] = itm
      inc(i)

proc cycle*[T](s: seq[T], n: Natural): seq[T] =
  ## Returns a new sequence with the items of `s` repeated `n` times.
  ##
  ## Example:
  ##
  ## .. code-block:
  ##
  ##   let
  ##     s = @[1, 2, 3]
  ##     total = s.cycle(3)
  ##   assert total == @[1, 2, 3, 1, 2, 3, 1, 2, 3]
  result = newSeq[T](n * s.len)
  var o = 0
  for x in 0..<n:
    for e in s:
      result[o] = e
      inc o

proc repeat*[T](x: T, n: Natural): seq[T] =
  ## Returns a new sequence with the item `x` repeated `n` times.
  ##
  ## Example:
  ##
  ## .. code-block:
  ##
  ##   let
  ##     total = repeat(5, 3)
  ##   assert total == @[5, 5, 5]
  result = newSeq[T](n)
  for i in 0..<n:
    result[i] = x

proc deduplicate*[T](seq1: seq[T]): seq[T] =
  ## Returns a new sequence without duplicates.
  ##
  ## .. code-block::
  ##   let
  ##     dup1 = @[1, 1, 3, 4, 2, 2, 8, 1, 4]
  ##     dup2 = @["a", "a", "c", "d", "d"]
  ##     unique1 = deduplicate(dup1)
  ##     unique2 = deduplicate(dup2)
  ##   assert unique1 == @[1, 3, 4, 2, 8]
  ##   assert unique2 == @["a", "c", "d"]
  result = @[]
  for itm in items(seq1):
    if not result.contains(itm): result.add(itm)

{.deprecated: [distnct: deduplicate].}

proc zip*[S, T](seq1: seq[S], seq2: seq[T]): seq[tuple[a: S, b: T]] =
  ## Returns a new sequence with a combination of the two input sequences.
  ##
  ## For convenience you can access the returned tuples through the named
  ## fields `a` and `b`. If one sequence is shorter, the remaining items in the
  ## longer sequence are discarded. Example:
  ##
  ## .. code-block::
  ##   let
  ##     short = @[1, 2, 3]
  ##     long = @[6, 5, 4, 3, 2, 1]
  ##     words = @["one", "two", "three"]
  ##     zip1 = zip(short, long)
  ##     zip2 = zip(short, words)
  ##   assert zip1 == @[(1, 6), (2, 5), (3, 4)]
  ##   assert zip2 == @[(1, "one"), (2, "two"), (3, "three")]
  ##   assert zip1[2].b == 4
  ##   assert zip2[2].b == "three"
  var m = min(seq1.len, seq2.len)
  newSeq(result, m)
  for i in 0 .. m-1: result[i] = (seq1[i], seq2[i])

proc distribute*[T](s: seq[T], num: Positive, spread = true): seq[seq[T]] =
  ## Splits and distributes a sequence `s` into `num` sub sequences.
  ##
  ## Returns a sequence of `num` sequences. For some input values this is the
  ## inverse of the `concat <#concat>`_ proc.  The proc will assert in debug
  ## builds if `s` is nil or `num` is less than one, and will likely crash on
  ## release builds.  The input sequence `s` can be empty, which will produce
  ## `num` empty sequences.
  ##
  ## If `spread` is false and the length of `s` is not a multiple of `num`, the
  ## proc will max out the first sub sequences with ``1 + len(s) div num``
  ## entries, leaving the remainder of elements to the last sequence.
  ##
  ## On the other hand, if `spread` is true, the proc will distribute evenly
  ## the remainder of the division across all sequences, which makes the result
  ## more suited to multithreading where you are passing equal sized work units
  ## to a thread pool and want to maximize core usage.
  ##
  ## Example:
  ##
  ## .. code-block::
  ##   let numbers = @[1, 2, 3, 4, 5, 6, 7]
  ##   assert numbers.distribute(3) == @[@[1, 2, 3], @[4, 5], @[6, 7]]
  ##   assert numbers.distribute(3, false)  == @[@[1, 2, 3], @[4, 5, 6], @[7]]
  ##   assert numbers.distribute(6)[0] == @[1, 2]
  ##   assert numbers.distribute(6)[5] == @[7]
  assert(not s.isNil, "`s` can't be nil")
  if num < 2:
    result = @[s]
    return

  let num = int(num) # XXX probably only needed because of .. bug

  # Create the result and calculate the stride size and the remainder if any.
  result = newSeq[seq[T]](num)
  var
    stride = s.len div num
    first = 0
    last = 0
    extra = s.len mod num

  if extra == 0 or spread == false:
    # Use an algorithm which overcounts the stride and minimizes reading limits.
    if extra > 0: inc(stride)

    for i in 0 .. <num:
      result[i] = newSeq[T]()
      for g in first .. <min(s.len, first + stride):
        result[i].add(s[g])
      first += stride

  else:
    # Use an undercounting algorithm which *adds* the remainder each iteration.
    for i in 0 .. <num:
      last = first + stride
      if extra > 0:
        extra -= 1
        inc(last)

      result[i] = newSeq[T]()
      for g in first .. <last:
        result[i].add(s[g])
      first = last


proc map*[T, S](data: openArray[T], op: proc (x: T): S {.closure.}):
                                                            seq[S]{.inline.} =
  ## Returns a new sequence with the results of `op` applied to every item in
  ## `data`.
  ##
  ## Since the input is not modified you can use this version of ``map`` to
  ## transform the type of the elements in the input sequence. Example:
  ##
  ## .. code-block:: nim
  ##   let
  ##     a = @[1, 2, 3, 4]
  ##     b = map(a, proc(x: int): string = $x)
  ##   assert b == @["1", "2", "3", "4"]
  newSeq(result, data.len)
  for i in 0..data.len-1: result[i] = op(data[i])

proc map*[T](data: var openArray[T], op: proc (x: var T) {.closure.})
                                                              {.deprecated.} =
  ## Applies `op` to every item in `data` modifying it directly.
  ##
  ## Note that this version of ``map`` requires your input and output types to
  ## be the same, since they are modified in-place. Example:
  ##
  ## .. code-block:: nim
  ##   var a = @["1", "2", "3", "4"]
  ##   echo repr(a)
  ##   # --> ["1", "2", "3", "4"]
  ##   map(a, proc(x: var string) = x &= "42")
  ##   echo repr(a)
  ##   # --> ["142", "242", "342", "442"]
  ## **Deprecated since version 0.12.0:** Use the ``apply`` proc instead.
  for i in 0..data.len-1: op(data[i])

proc apply*[T](data: var seq[T], op: proc (x: var T) {.closure.})
                                                              {.inline.} =
  ## Applies `op` to every item in `data` modifying it directly.
  ##
  ## Note that this requires your input and output types to
  ## be the same, since they are modified in-place.
  ## The parameter function takes a ``var T`` type parameter.
  ## Example:
  ##
  ## .. code-block:: nim
  ##   var a = @["1", "2", "3", "4"]
  ##   echo repr(a)
  ##   # --> ["1", "2", "3", "4"]
  ##   map(a, proc(x: var string) = x &= "42")
  ##   echo repr(a)
  ##   # --> ["142", "242", "342", "442"]
  ##
  for i in 0..data.len-1: op(data[i])

proc apply*[T](data: var seq[T], op: proc (x: T): T {.closure.})
                                                              {.inline.} =
  ## Applies `op` to every item in `data` modifying it directly.
  ##
  ## Note that this requires your input and output types to
  ## be the same, since they are modified in-place.
  ## The parameter function takes and returns a ``T`` type variable.
  ## Example:
  ##
  ## .. code-block:: nim
  ##   var a = @["1", "2", "3", "4"]
  ##   echo repr(a)
  ##   # --> ["1", "2", "3", "4"]
  ##   map(a, proc(x: string): string = x & "42")
  ##   echo repr(a)
  ##   # --> ["142", "242", "342", "442"]
  ##
  for i in 0..data.len-1: data[i] = op(data[i])


iterator filter*[T](seq1: seq[T], pred: proc(item: T): bool {.closure.}): T =
  ## Iterates through a sequence and yields every item that fulfills the
  ## predicate.
  ##
  ## Example:
  ##
  ## .. code-block::
  ##   let numbers = @[1, 4, 5, 8, 9, 7, 4]
  ##   for n in filter(numbers, proc (x: int): bool = x mod 2 == 0):
  ##     echo($n)
  ##   # echoes 4, 8, 4 in separate lines
  for i in 0..<seq1.len:
    if pred(seq1[i]):
      yield seq1[i]

proc filter*[T](seq1: seq[T], pred: proc(item: T): bool {.closure.}): seq[T]
                                                                  {.inline.} =
  ## Returns a new sequence with all the items that fulfilled the predicate.
  ##
  ## Example:
  ##
  ## .. code-block::
  ##   let
  ##     colors = @["red", "yellow", "black"]
  ##     f1 = filter(colors, proc(x: string): bool = x.len < 6)
  ##     f2 = filter(colors) do (x: string) -> bool : x.len > 5
  ##   assert f1 == @["red", "black"]
  ##   assert f2 == @["yellow"]
  result = newSeq[T]()
  for i in 0..<seq1.len:
    if pred(seq1[i]):
      result.add(seq1[i])

proc keepIf*[T](seq1: var seq[T], pred: proc(item: T): bool {.closure.})
                                                                {.inline.} =
  ## Keeps the items in the passed sequence if they fulfilled the predicate.
  ## Same as the ``filter`` proc, but modifies the sequence directly.
  ##
  ## Example:
  ##
  ## .. code-block::
  ##   var floats = @[13.0, 12.5, 5.8, 2.0, 6.1, 9.9, 10.1]
  ##   keepIf(floats, proc(x: float): bool = x > 10)
  ##   assert floats == @[13.0, 12.5, 10.1]
  var pos = 0
  for i in 0 .. <len(seq1):
    if pred(seq1[i]):
      if pos != i:
        shallowCopy(seq1[pos], seq1[i])
      inc(pos)
  setLen(seq1, pos)

proc delete*[T](s: var seq[T]; first, last: Natural) =
  ## Deletes in `s` the items at position `first` .. `last`. This modifies
  ## `s` itself, it does not return a copy.
  ##
  ## Example:
  ##
  ##.. code-block::
  ##   let outcome = @[1,1,1,1,1,1,1,1]
  ##   var dest = @[1,1,1,2,2,2,2,2,2,1,1,1,1,1]
  ##   dest.delete(3, 8)
  ##   assert outcome == dest

  var i = first
  var j = last+1
  var newLen = len(s)-j+i
  while i < newLen:
    s[i].shallowCopy(s[j])
    inc(i)
    inc(j)
  setLen(s, newLen)

proc insert*[T](dest: var seq[T], src: openArray[T], pos=0) =
  ## Inserts items from `src` into `dest` at position `pos`. This modifies
  ## `dest` itself, it does not return a copy.
  ##
  ## Example:
  ##
  ##.. code-block::
  ##   var dest = @[1,1,1,1,1,1,1,1]
  ##   let
  ##     src = @[2,2,2,2,2,2]
  ##     outcome = @[1,1,1,2,2,2,2,2,2,1,1,1,1,1]
  ##   dest.insert(src, 3)
  ##   assert dest == outcome

  var j = len(dest) - 1
  var i = len(dest) + len(src) - 1
  dest.setLen(i + 1)

  # Move items after `pos` to the end of the sequence.
  while j >= pos:
    dest[i].shallowCopy(dest[j])
    dec(i)
    dec(j)
  # Insert items from `dest` into `dest` at `pos`
  inc(j)
  for item in src:
    dest[j] = item
    inc(j)


template filterIt*(seq1, pred: expr): expr =
  ## Returns a new sequence with all the items that fulfilled the predicate.
  ##
  ## Unlike the `proc` version, the predicate needs to be an expression using
  ## the ``it`` variable for testing, like: ``filterIt("abcxyz", it == 'x')``.
  ## Example:
  ##
  ## .. code-block::
  ##    let
  ##      temperatures = @[-272.15, -2.0, 24.5, 44.31, 99.9, -113.44]
  ##      acceptable = filterIt(temperatures, it < 50 and it > -10)
  ##      notAcceptable = filterIt(temperatures, it > 50 or it < -10)
  ##    assert acceptable == @[-2.0, 24.5, 44.31]
  ##    assert notAcceptable == @[-272.15, 99.9, -113.44]
  var result {.gensym.} = newSeq[type(seq1[0])]()
  for it {.inject.} in items(seq1):
    if pred: result.add(it)
  result

template keepItIf*(varSeq: seq, pred: expr) =
  ## Convenience template around the ``keepIf`` proc to reduce typing.
  ##
  ## Unlike the `proc` version, the predicate needs to be an expression using
  ## the ``it`` variable for testing, like: ``keepItIf("abcxyz", it == 'x')``.
  ## Example:
  ##
  ## .. code-block::
  ##   var candidates = @["foo", "bar", "baz", "foobar"]
  ##   keepItIf(candidates, it.len == 3 and it[0] == 'b')
  ##   assert candidates == @["bar", "baz"]
  var pos = 0
  for i in 0 .. <len(varSeq):
    let it {.inject.} = varSeq[i]
    if pred:
      if pos != i:
        shallowCopy(varSeq[pos], varSeq[i])
      inc(pos)
  setLen(varSeq, pos)

proc all*[T](seq1: seq[T], pred: proc(item: T): bool {.closure.}): bool =
  ## Iterates through a sequence and checks if every item fulfills the
  ## predicate.
  ##
  ## Example:
  ##
  ## .. code-block::
  ##   let numbers = @[1, 4, 5, 8, 9, 7, 4]
  ##   assert all(numbers, proc (x: int): bool = return x < 10) == true
  ##   assert all(numbers, proc (x: int): bool = return x < 9) == false
  for i in seq1:
    if not pred(i):
      return false
  return true

template allIt*(seq1, pred: expr): bool {.immediate.} =
  ## Checks if every item fulfills the predicate.
  ##
  ## Example:
  ##
  ## .. code-block::
  ##   let numbers = @[1, 4, 5, 8, 9, 7, 4]
  ##   assert allIt(numbers, it < 10) == true
  ##   assert allIt(numbers, it < 9) == false
  var result {.gensym.} = true
  for it {.inject.} in items(seq1):
    if not pred:
      result = false
      break
  result

proc any*[T](seq1: seq[T], pred: proc(item: T): bool {.closure.}): bool =
  ## Iterates through a sequence and checks if some item fulfills the
  ## predicate.
  ##
  ## Example:
  ##
  ## .. code-block::
  ##   let numbers = @[1, 4, 5, 8, 9, 7, 4]
  ##   assert any(numbers, proc (x: int): bool = return x > 8) == true
  ##   assert any(numbers, proc (x: int): bool = return x > 9) == false
  for i in seq1:
    if pred(i):
      return true
  return false

template anyIt*(seq1, pred: expr): bool {.immediate.} =
  ## Checks if some item fulfills the predicate.
  ##
  ## Example:
  ##
  ## .. code-block::
  ##   let numbers = @[1, 4, 5, 8, 9, 7, 4]
  ##   assert anyIt(numbers, it > 8) == true
  ##   assert anyIt(numbers, it > 9) == false
  var result {.gensym.} = false
  for it {.inject.} in items(seq1):
    if pred:
      result = true
      break
  result

template toSeq*(iter: expr): expr {.immediate.} =
  ## Transforms any iterator into a sequence.
  ##
  ## Example:
  ##
  ## .. code-block::
  ##   let
  ##     numeric = @[1, 2, 3, 4, 5, 6, 7, 8, 9]
  ##     odd_numbers = toSeq(filter(numeric) do (x: int) -> bool:
  ##       if x mod 2 == 1:
  ##         result = true)
  ##   assert odd_numbers == @[1, 3, 5, 7, 9]
  
  when compiles(iter.len):
    var i = 0
    var result = newSeq[type(iter)](iter.len)
    for x in iter:
      result[i] = x
      inc i
    result
  else:
    var result: seq[type(iter)] = @[]
    for x in iter:
      result.add(x)
    result

template foldl*(sequence, operation: expr): expr =
  ## Template to fold a sequence from left to right, returning the accumulation.
  ##
  ## The sequence is required to have at least a single element. Debug versions
  ## of your program will assert in this situation but release versions will
  ## happily go ahead. If the sequence has a single element it will be returned
  ## without applying ``operation``.
  ##
  ## The ``operation`` parameter should be an expression which uses the
  ## variables ``a`` and ``b`` for each step of the fold. Since this is a left
  ## fold, for non associative binary operations like subtraction think that
  ## the sequence of numbers 1, 2 and 3 will be parenthesized as (((1) - 2) -
  ## 3).  Example:
  ##
  ## .. code-block::
  ##   let
  ##     numbers = @[5, 9, 11]
  ##     addition = foldl(numbers, a + b)
  ##     subtraction = foldl(numbers, a - b)
  ##     multiplication = foldl(numbers, a * b)
  ##     words = @["nim", "is", "cool"]
  ##     concatenation = foldl(words, a & b)
  ##   assert addition == 25, "Addition is (((5)+9)+11)"
  ##   assert subtraction == -15, "Subtraction is (((5)-9)-11)"
  ##   assert multiplication == 495, "Multiplication is (((5)*9)*11)"
  ##   assert concatenation == "nimiscool"
  assert sequence.len > 0, "Can't fold empty sequences"
  var result {.gensym.}: type(sequence[0])
  result = sequence[0]
  for i in 1..<sequence.len:
    let
      a {.inject.} = result
      b {.inject.} = sequence[i]
    result = operation
  result

template foldr*(sequence, operation: expr): expr =
  ## Template to fold a sequence from right to left, returning the accumulation.
  ##
  ## The sequence is required to have at least a single element. Debug versions
  ## of your program will assert in this situation but release versions will
  ## happily go ahead. If the sequence has a single element it will be returned
  ## without applying ``operation``.
  ##
  ## The ``operation`` parameter should be an expression which uses the
  ## variables ``a`` and ``b`` for each step of the fold. Since this is a right
  ## fold, for non associative binary operations like subtraction think that
  ## the sequence of numbers 1, 2 and 3 will be parenthesized as (1 - (2 -
  ## (3))). Example:
  ##
  ## .. code-block::
  ##   let
  ##     numbers = @[5, 9, 11]
  ##     addition = foldr(numbers, a + b)
  ##     subtraction = foldr(numbers, a - b)
  ##     multiplication = foldr(numbers, a * b)
  ##     words = @["nim", "is", "cool"]
  ##     concatenation = foldr(words, a & b)
  ##   assert addition == 25, "Addition is (5+(9+(11)))"
  ##   assert subtraction == 7, "Subtraction is (5-(9-(11)))"
  ##   assert multiplication == 495, "Multiplication is (5*(9*(11)))"
  ##   assert concatenation == "nimiscool"
  assert sequence.len > 0, "Can't fold empty sequences"
  var result {.gensym.}: type(sequence[0])
  result = sequence[sequence.len - 1]
  for i in countdown(sequence.len - 2, 0):
    let
      a {.inject.} = sequence[i]
      b {.inject.} = result
    result = operation
  result

template mapIt*(seq1, typ, op: expr): expr {.deprecated.}=
  ## Convenience template around the ``map`` proc to reduce typing.
  ##
  ## The template injects the ``it`` variable which you can use directly in an
  ## expression. You also need to pass as `typ` the type of the expression,
  ## since the new returned sequence can have a different type than the
  ## original.  Example:
  ##
  ## .. code-block::
  ##   let
  ##     nums = @[1, 2, 3, 4]
  ##     strings = nums.mapIt(string, $(4 * it))
  ##   assert strings == @["4", "8", "12", "16"]
  ## **Deprecated since version 0.12.0:** Use the ``mapIt(seq1, op)``
  ##   template instead.
  var result {.gensym.}: seq[typ] = @[]
  for it {.inject.} in items(seq1):
    result.add(op)
  result


template mapIt*(seq1, op: expr): expr =
  ## Convenience template around the ``map`` proc to reduce typing.
  ##
  ## The template injects the ``it`` variable which you can use directly in an
  ## expression. Example:
  ##
  ## .. code-block::
  ##   let
  ##     nums = @[1, 2, 3, 4]
  ##     strings = nums.mapIt($(4 * it))
  ##   assert strings == @["4", "8", "12", "16"]
  type outType = type((
    block:
      var it{.inject.}: type(items(seq1));
      op))
  var result: seq[outType]
  when compiles(seq1.len):
    let s = seq1
    var i = 0
    result = newSeq[outType](s.len)
    for it {.inject.} in s:
      result[i] = op
      i += 1
  else:
    result = @[]
    for it {.inject.} in seq1:
      result.add(op)
  result

template applyIt*(varSeq, op: expr) =
  ## Convenience template around the mutable ``apply`` proc to reduce typing.
  ##
  ## The template injects the ``it`` variable which you can use directly in an
  ## expression. The expression has to return the same type as the sequence you
  ## are mutating. Example:
  ##
  ## .. code-block::
  ##   var nums = @[1, 2, 3, 4]
  ##   nums.applyIt(it * 3)
  ##   assert nums[0] + nums[3] == 15
  for i in 0 .. <varSeq.len:
    let it {.inject.} = varSeq[i]
    varSeq[i] = op



template newSeqWith*(len: int, init: expr): expr =
  ## creates a new sequence, calling `init` to initialize each value. Example:
  ##
  ## .. code-block::
  ##   var seq2D = newSeqWith(20, newSeq[bool](10))
  ##   seq2D[0][0] = true
  ##   seq2D[1][0] = true
  ##   seq2D[0][1] = true
  ##
  ##   import math
  ##   var seqRand = newSeqWith(20, random(10))
  ##   echo seqRand
  var result {.gensym.} = newSeq[type(init)](len)
  for i in 0 .. <len:
    result[i] = init
  result

when isMainModule:
  import strutils
  block: # concat test
    let
      s1 = @[1, 2, 3]
      s2 = @[4, 5]
      s3 = @[6, 7]
      total = concat(s1, s2, s3)
    assert total == @[1, 2, 3, 4, 5, 6, 7]

  block: # duplicates test
    let
      dup1 = @[1, 1, 3, 4, 2, 2, 8, 1, 4]
      dup2 = @["a", "a", "c", "d", "d"]
      unique1 = deduplicate(dup1)
      unique2 = deduplicate(dup2)
    assert unique1 == @[1, 3, 4, 2, 8]
    assert unique2 == @["a", "c", "d"]

  block: # zip test
    let
      short = @[1, 2, 3]
      long = @[6, 5, 4, 3, 2, 1]
      words = @["one", "two", "three"]
      zip1 = zip(short, long)
      zip2 = zip(short, words)
    assert zip1 == @[(1, 6), (2, 5), (3, 4)]
    assert zip2 == @[(1, "one"), (2, "two"), (3, "three")]
    assert zip1[2].b == 4
    assert zip2[2].b == "three"

  block: # filter proc test
    let
      colors = @["red", "yellow", "black"]
      f1 = filter(colors, proc(x: string): bool = x.len < 6)
      f2 = filter(colors) do (x: string) -> bool : x.len > 5
    assert f1 == @["red", "black"]
    assert f2 == @["yellow"]

  block: # filter iterator test
    let numbers = @[1, 4, 5, 8, 9, 7, 4]
    assert toSeq(filter(numbers, proc (x: int): bool = x mod 2 == 0)) ==
      @[4, 8, 4]

  block: # keepIf test
    var floats = @[13.0, 12.5, 5.8, 2.0, 6.1, 9.9, 10.1]
    keepIf(floats, proc(x: float): bool = x > 10)
    assert floats == @[13.0, 12.5, 10.1]

  block: # filterIt test
    let
      temperatures = @[-272.15, -2.0, 24.5, 44.31, 99.9, -113.44]
      acceptable = filterIt(temperatures, it < 50 and it > -10)
      notAcceptable = filterIt(temperatures, it > 50 or it < -10)
    assert acceptable == @[-2.0, 24.5, 44.31]
    assert notAcceptable == @[-272.15, 99.9, -113.44]

  block: # keepItIf test
    var candidates = @["foo", "bar", "baz", "foobar"]
    keepItIf(candidates, it.len == 3 and it[0] == 'b')
    assert candidates == @["bar", "baz"]

  block: # any
    let
      numbers = @[1, 4, 5, 8, 9, 7, 4]
      len0seq : seq[int] = @[]
    assert any(numbers, proc (x: int): bool = return x > 8) == true
    assert any(numbers, proc (x: int): bool = return x > 9) == false
    assert any(len0seq, proc (x: int): bool = return true) == false

  block: # anyIt
    let
      numbers = @[1, 4, 5, 8, 9, 7, 4]
      len0seq : seq[int] = @[]
    assert anyIt(numbers, it > 8) == true
    assert anyIt(numbers, it > 9) == false
    assert anyIt(len0seq, true) == false

  block: # all
    let
      numbers = @[1, 4, 5, 8, 9, 7, 4]
      len0seq : seq[int] = @[]
    assert all(numbers, proc (x: int): bool = return x < 10) == true
    assert all(numbers, proc (x: int): bool = return x < 9) == false
    assert all(len0seq, proc (x: int): bool = return false) == true

  block: # allIt
    let
      numbers = @[1, 4, 5, 8, 9, 7, 4]
      len0seq : seq[int] = @[]
    assert allIt(numbers, it < 10) == true
    assert allIt(numbers, it < 9) == false
    assert allIt(len0seq, false) == true

  block: # toSeq test
    let
      numeric = @[1, 2, 3, 4, 5, 6, 7, 8, 9]
      odd_numbers = toSeq(filter(numeric) do (x: int) -> bool:
        if x mod 2 == 1:
          result = true)
    assert odd_numbers == @[1, 3, 5, 7, 9]

  block: # foldl tests
    let
      numbers = @[5, 9, 11]
      addition = foldl(numbers, a + b)
      subtraction = foldl(numbers, a - b)
      multiplication = foldl(numbers, a * b)
      words = @["nim", "is", "cool"]
      concatenation = foldl(words, a & b)
    assert addition == 25, "Addition is (((5)+9)+11)"
    assert subtraction == -15, "Subtraction is (((5)-9)-11)"
    assert multiplication == 495, "Multiplication is (((5)*9)*11)"
    assert concatenation == "nimiscool"

  block: # foldr tests
    let
      numbers = @[5, 9, 11]
      addition = foldr(numbers, a + b)
      subtraction = foldr(numbers, a - b)
      multiplication = foldr(numbers, a * b)
      words = @["nim", "is", "cool"]
      concatenation = foldr(words, a & b)
    assert addition == 25, "Addition is (5+(9+(11)))"
    assert subtraction == 7, "Subtraction is (5-(9-(11)))"
    assert multiplication == 495, "Multiplication is (5*(9*(11)))"
    assert concatenation == "nimiscool"

  block: # delete tests
    let outcome = @[1,1,1,1,1,1,1,1]
    var dest = @[1,1,1,2,2,2,2,2,2,1,1,1,1,1]
    dest.delete(3, 8)
    assert outcome == dest, """\
    Deleting range 3-9 from [1,1,1,2,2,2,2,2,2,1,1,1,1,1]
    is [1,1,1,1,1,1,1,1]"""

  block: # insert tests
    var dest = @[1,1,1,1,1,1,1,1]
    let
      src = @[2,2,2,2,2,2]
      outcome = @[1,1,1,2,2,2,2,2,2,1,1,1,1,1]
    dest.insert(src, 3)
    assert dest == outcome, """\
    Inserting [2,2,2,2,2,2] into [1,1,1,1,1,1,1,1]
    at 3 is [1,1,1,2,2,2,2,2,2,1,1,1,1,1]"""

  block: # mapIt tests
    var
      nums = @[1, 2, 3, 4]
      strings = nums.mapIt($(4 * it))
    nums.applyIt(it * 3)
    assert nums[0] + nums[3] == 15

  block: # distribute tests
    let numbers = @[1, 2, 3, 4, 5, 6, 7]
    doAssert numbers.distribute(3) == @[@[1, 2, 3], @[4, 5], @[6, 7]]
    doAssert numbers.distribute(6)[0] == @[1, 2]
    doAssert numbers.distribute(6)[5] == @[7]
    let a = @[1, 2, 3, 4, 5, 6, 7]
    doAssert a.distribute(1, true)   == @[@[1, 2, 3, 4, 5, 6, 7]]
    doAssert a.distribute(1, false)  == @[@[1, 2, 3, 4, 5, 6, 7]]
    doAssert a.distribute(2, true)   == @[@[1, 2, 3, 4], @[5, 6, 7]]
    doAssert a.distribute(2, false)  == @[@[1, 2, 3, 4], @[5, 6, 7]]
    doAssert a.distribute(3, true)   == @[@[1, 2, 3], @[4, 5], @[6, 7]]
    doAssert a.distribute(3, false)  == @[@[1, 2, 3], @[4, 5, 6], @[7]]
    doAssert a.distribute(4, true)   == @[@[1, 2], @[3, 4], @[5, 6], @[7]]
    doAssert a.distribute(4, false)  == @[@[1, 2], @[3, 4], @[5, 6], @[7]]
    doAssert a.distribute(5, true)   == @[@[1, 2], @[3, 4], @[5], @[6], @[7]]
    doAssert a.distribute(5, false)  == @[@[1, 2], @[3, 4], @[5, 6], @[7], @[]]
    doAssert a.distribute(6, true)   == @[@[1, 2], @[3], @[4], @[5], @[6], @[7]]
    doAssert a.distribute(6, false)  == @[
      @[1, 2], @[3, 4], @[5, 6], @[7], @[], @[]]
    doAssert a.distribute(8, false)  == a.distribute(8, true)
    doAssert a.distribute(90, false) == a.distribute(90, true)
    var b = @[0]
    for f in 1 .. 25: b.add(f)
    doAssert b.distribute(5, true)[4].len == 5
    doAssert b.distribute(5, false)[4].len == 2

  block: # newSeqWith tests
    var seq2D = newSeqWith(4, newSeq[bool](2))
    seq2D[0][0] = true
    seq2D[1][0] = true
    seq2D[0][1] = true
    doAssert seq2D == @[@[true, true], @[true, false], @[false, false], @[false, false]]

  block: # cycle tests
    let
      a = @[1, 2, 3]
      b: seq[int] = @[]

    doAssert a.cycle(3) == @[1, 2, 3, 1, 2, 3, 1, 2, 3]
    doAssert a.cycle(0) == @[]
    #doAssert a.cycle(-1) == @[] # will not compile!
    doAssert b.cycle(3) == @[]

  block: # repeat tests
    assert repeat(10, 5) == @[10, 10, 10, 10, 10]
    assert repeat(@[1,2,3], 2) == @[@[1,2,3], @[1,2,3]]

  when not defined(testing):
    echo "Finished doc tests"

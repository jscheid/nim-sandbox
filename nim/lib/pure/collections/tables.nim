#
#
#            Nim's Runtime Library
#        (c) Copyright 2015 Andreas Rumpf
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.
#

## The ``tables`` module implements variants of an efficient `hash table`:idx:
## (also often named `dictionary`:idx: in other programming languages) that is
## a mapping from keys to values. ``Table`` is the usual hash table,
## ``OrderedTable`` is like ``Table`` but remembers insertion order
## and ``CountTable`` is a mapping from a key to its number of occurrences.
## For consistency with every other data type in Nim these have **value**
## semantics, this means that ``=`` performs a copy of the hash table.
## For **reference** semantics use the ``Ref`` variant: ``TableRef``,
## ``OrderedTableRef``, ``CountTableRef``.
##
## If you are using simple standard types like ``int`` or ``string`` for the
## keys of the table you won't have any problems, but as soon as you try to use
## a more complex object as a key you will be greeted by a strange compiler
## error::
##
##   Error: type mismatch: got (Person)
##   but expected one of:
##   hashes.hash(x: openarray[A]): Hash
##   hashes.hash(x: int): Hash
##   hashes.hash(x: float): Hash
##   …
##
## What is happening here is that the types used for table keys require to have
## a ``hash()`` proc which will convert them to a `Hash <hashes.html#Hash>`_
## value, and the compiler is listing all the hash functions it knows.
## Additionally there has to be a ``==`` operator that provides the same
## semantics as its corresponding ``hash`` proc.
##
## After you add ``hash`` and ``==`` for your custom type everything will work.
## Currently however ``hash`` for objects is not defined, whereas
## ``system.==`` for objects does exist and performs a "deep" comparison (every
## field is compared) which is usually what you want. So in the following
## example implementing only ``hash`` suffices:
##
## .. code-block::
##   type
##     Person = object
##       firstName, lastName: string
##
##   proc hash(x: Person): Hash =
##     ## Piggyback on the already available string hash proc.
##     ##
##     ## Without this proc nothing works!
##     result = x.firstName.hash !& x.lastName.hash
##     result = !$result
##
##   var
##     salaries = initTable[Person, int]()
##     p1, p2: Person
##
##   p1.firstName = "Jon"
##   p1.lastName = "Ross"
##   salaries[p1] = 30_000
##
##   p2.firstName = "소진"
##   p2.lastName = "박"
##   salaries[p2] = 45_000

import
  hashes, math

include "system/inclrtl"

type
  KeyValuePair[A, B] = tuple[hcode: Hash, key: A, val: B]
  KeyValuePairSeq[A, B] = seq[KeyValuePair[A, B]]
  Table*[A, B] = object ## generic hash table
    data: KeyValuePairSeq[A, B]
    counter: int
  TableRef*[A,B] = ref Table[A, B]

{.deprecated: [TTable: Table, PTable: TableRef].}

template maxHash(t): expr {.immediate.} = high(t.data)
template dataLen(t): expr = len(t.data)

include tableimpl

proc rightSize*(count: Natural): int {.inline.} =
  ## Return the value of `initialSize` to support `count` items.
  ##
  ## If more items are expected to be added, simply add that
  ## expected extra amount to the parameter before calling this.
  ##
  ## Internally, we want mustRehash(rightSize(x), x) == false.
  result = nextPowerOfTwo(count * 3 div 2  +  4)

proc len*[A, B](t: Table[A, B]): int =
  ## returns the number of keys in `t`.
  result = t.counter

template get(t, key): untyped {.immediate.} =
  ## retrieves the value at ``t[key]``. The value can be modified.
  ## If `key` is not in `t`, the ``KeyError`` exception is raised.
  mixin rawGet
  var hc: Hash
  var index = rawGet(t, key, hc)
  if index >= 0: result = t.data[index].val
  else:
    when compiles($key):
      raise newException(KeyError, "key not found: " & $key)
    else:
      raise newException(KeyError, "key not found")

template getOrDefaultImpl(t, key): untyped {.immediate.} =
  mixin rawGet
  var hc: Hash
  var index = rawGet(t, key, hc)
  if index >= 0: result = t.data[index].val

proc `[]`*[A, B](t: Table[A, B], key: A): B {.deprecatedGet.} =
  ## retrieves the value at ``t[key]``. If `key` is not in `t`, the
  ## ``KeyError`` exception is raised. One can check with ``hasKey`` whether
  ## the key exists.
  get(t, key)

proc `[]`*[A, B](t: var Table[A, B], key: A): var B {.deprecatedGet.} =
  ## retrieves the value at ``t[key]``. The value can be modified.
  ## If `key` is not in `t`, the ``KeyError`` exception is raised.
  get(t, key)

proc mget*[A, B](t: var Table[A, B], key: A): var B {.deprecated.} =
  ## retrieves the value at ``t[key]``. The value can be modified.
  ## If `key` is not in `t`, the ``KeyError`` exception is raised. Use ```[]```
  ## instead.
  get(t, key)

proc getOrDefault*[A, B](t: Table[A, B], key: A): B = getOrDefaultImpl(t, key)

iterator allValues*[A, B](t: Table[A, B]; key: A): B =
  ## iterates over any value in the table `t` that belongs to the given `key`.
  var h: Hash = hash(key) and high(t.data)
  while isFilled(t.data[h].hcode):
    if t.data[h].key == key:
      yield t.data[h].val
    h = nextTry(h, high(t.data))

proc hasKey*[A, B](t: Table[A, B], key: A): bool =
  ## returns true iff `key` is in the table `t`.
  var hc: Hash
  result = rawGet(t, key, hc) >= 0

proc contains*[A, B](t: Table[A, B], key: A): bool =
  ## alias of `hasKey` for use with the `in` operator.
  return hasKey[A, B](t, key)

iterator pairs*[A, B](t: Table[A, B]): (A, B) =
  ## iterates over any (key, value) pair in the table `t`.
  for h in 0..high(t.data):
    if isFilled(t.data[h].hcode): yield (t.data[h].key, t.data[h].val)

iterator mpairs*[A, B](t: var Table[A, B]): (A, var B) =
  ## iterates over any (key, value) pair in the table `t`. The values
  ## can be modified.
  for h in 0..high(t.data):
    if isFilled(t.data[h].hcode): yield (t.data[h].key, t.data[h].val)

iterator keys*[A, B](t: Table[A, B]): A =
  ## iterates over any key in the table `t`.
  for h in 0..high(t.data):
    if isFilled(t.data[h].hcode): yield t.data[h].key

iterator values*[A, B](t: Table[A, B]): B =
  ## iterates over any value in the table `t`.
  for h in 0..high(t.data):
    if isFilled(t.data[h].hcode): yield t.data[h].val

iterator mvalues*[A, B](t: var Table[A, B]): var B =
  ## iterates over any value in the table `t`. The values can be modified.
  for h in 0..high(t.data):
    if isFilled(t.data[h].hcode): yield t.data[h].val

proc del*[A, B](t: var Table[A, B], key: A) =
  ## deletes `key` from hash table `t`.
  delImpl()

proc enlarge[A, B](t: var Table[A, B]) =
  var n: KeyValuePairSeq[A, B]
  newSeq(n, len(t.data) * growthFactor)
  swap(t.data, n)
  for i in countup(0, high(n)):
    if isFilled(n[i].hcode):
      var j = -1 - rawGetKnownHC(t, n[i].key, n[i].hcode)
      rawInsert(t, t.data, n[i].key, n[i].val, n[i].hcode, j)

proc mgetOrPut*[A, B](t: var Table[A, B], key: A, val: B): var B =
  ## retrieves value at ``t[key]`` or puts ``val`` if not present, either way
  ## returning a value which can be modified.
  mgetOrPutImpl(enlarge)

proc hasKeyOrPut*[A, B](t: var Table[A, B], key: A, val: B): bool =
  ## returns true iff `key` is in the table, otherwise inserts `value`.
  hasKeyOrPutImpl(enlarge)

proc `[]=`*[A, B](t: var Table[A, B], key: A, val: B) =
  ## puts a (key, value)-pair into `t`.
  putImpl(enlarge)

proc add*[A, B](t: var Table[A, B], key: A, val: B) =
  ## puts a new (key, value)-pair into `t` even if ``t[key]`` already exists.
  addImpl(enlarge)

proc len*[A, B](t: TableRef[A, B]): int =
  ## returns the number of keys in `t`.
  result = t.counter

proc initTable*[A, B](initialSize=64): Table[A, B] =
  ## creates a new hash table that is empty.
  ##
  ## `initialSize` needs to be a power of two. If you need to accept runtime
  ## values for this you could use the ``nextPowerOfTwo`` proc from the
  ## `math <math.html>`_ module or the ``rightSize`` proc from this module.
  assert isPowerOfTwo(initialSize)
  result.counter = 0
  newSeq(result.data, initialSize)

proc toTable*[A, B](pairs: openArray[(A,
                    B)]): Table[A, B] =
  ## creates a new hash table that contains the given `pairs`.
  result = initTable[A, B](rightSize(pairs.len))
  for key, val in items(pairs): result[key] = val

template dollarImpl(): stmt {.dirty.} =
  if t.len == 0:
    result = "{:}"
  else:
    result = "{"
    for key, val in pairs(t):
      if result.len > 1: result.add(", ")
      result.add($key)
      result.add(": ")
      result.add($val)
    result.add("}")

proc `$`*[A, B](t: Table[A, B]): string =
  ## The `$` operator for hash tables.
  dollarImpl()

proc hasKey*[A, B](t: TableRef[A, B], key: A): bool =
  ## returns true iff `key` is in the table `t`.
  result = t[].hasKey(key)

template equalsImpl() =
  if s.counter == t.counter:
    # different insertion orders mean different 'data' seqs, so we have
    # to use the slow route here:
    for key, val in s:
      # prefix notation leads to automatic dereference in case of PTable
      if not t.hasKey(key): return false
      if t[key] != val: return false
    return true

proc `==`*[A, B](s, t: Table[A, B]): bool =
  equalsImpl()

proc indexBy*[A, B, C](collection: A, index: proc(x: B): C): Table[C, B] =
  ## Index the collection with the proc provided.
  # TODO: As soon as supported, change collection: A to collection: A[B]
  result = initTable[C, B]()
  for item in collection:
    result[index(item)] = item

iterator pairs*[A, B](t: TableRef[A, B]): (A, B) =
  ## iterates over any (key, value) pair in the table `t`.
  for h in 0..high(t.data):
    if isFilled(t.data[h].hcode): yield (t.data[h].key, t.data[h].val)

iterator mpairs*[A, B](t: TableRef[A, B]): (A, var B) =
  ## iterates over any (key, value) pair in the table `t`. The values
  ## can be modified.
  for h in 0..high(t.data):
    if isFilled(t.data[h].hcode): yield (t.data[h].key, t.data[h].val)

iterator keys*[A, B](t: TableRef[A, B]): A =
  ## iterates over any key in the table `t`.
  for h in 0..high(t.data):
    if isFilled(t.data[h].hcode): yield t.data[h].key

iterator values*[A, B](t: TableRef[A, B]): B =
  ## iterates over any value in the table `t`.
  for h in 0..high(t.data):
    if isFilled(t.data[h].hcode): yield t.data[h].val

iterator mvalues*[A, B](t: TableRef[A, B]): var B =
  ## iterates over any value in the table `t`. The values can be modified.
  for h in 0..high(t.data):
    if isFilled(t.data[h].hcode): yield t.data[h].val

proc `[]`*[A, B](t: TableRef[A, B], key: A): var B {.deprecatedGet.} =
  ## retrieves the value at ``t[key]``.  If `key` is not in `t`, the
  ## ``KeyError`` exception is raised. One can check with ``hasKey`` whether
  ## the key exists.
  result = t[][key]

proc mget*[A, B](t: TableRef[A, B], key: A): var B {.deprecated.} =
  ## retrieves the value at ``t[key]``. The value can be modified.
  ## If `key` is not in `t`, the ``KeyError`` exception is raised.
  ## Use ```[]``` instead.
  t[][key]

proc getOrDefault*[A, B](t: TableRef[A, B], key: A): B = getOrDefault(t[], key)

proc mgetOrPut*[A, B](t: TableRef[A, B], key: A, val: B): var B =
  ## retrieves value at ``t[key]`` or puts ``val`` if not present, either way
  ## returning a value which can be modified.
  t[].mgetOrPut(key, val)

proc hasKeyOrPut*[A, B](t: var TableRef[A, B], key: A, val: B): bool =
  ## returns true iff `key` is in the table, otherwise inserts `value`.
  t[].hasKeyOrPut(key, val)

proc contains*[A, B](t: TableRef[A, B], key: A): bool =
  ## alias of `hasKey` for use with the `in` operator.
  return hasKey[A, B](t, key)

proc `[]=`*[A, B](t: TableRef[A, B], key: A, val: B) =
  ## puts a (key, value)-pair into `t`.
  t[][key] = val

proc add*[A, B](t: TableRef[A, B], key: A, val: B) =
  ## puts a new (key, value)-pair into `t` even if ``t[key]`` already exists.
  t[].add(key, val)

proc del*[A, B](t: TableRef[A, B], key: A) =
  ## deletes `key` from hash table `t`.
  t[].del(key)

proc newTable*[A, B](initialSize=64): TableRef[A, B] =
  new(result)
  result[] = initTable[A, B](initialSize)

proc newTable*[A, B](pairs: openArray[(A, B)]): TableRef[A, B] =
  ## creates a new hash table that contains the given `pairs`.
  new(result)
  result[] = toTable[A, B](pairs)

proc `$`*[A, B](t: TableRef[A, B]): string =
  ## The `$` operator for hash tables.
  dollarImpl()

proc `==`*[A, B](s, t: TableRef[A, B]): bool =
  if isNil(s): result = isNil(t)
  elif isNil(t): result = false
  else: equalsImpl()

proc newTableFrom*[A, B, C](collection: A, index: proc(x: B): C): TableRef[C, B] =
  ## Index the collection with the proc provided.
  # TODO: As soon as supported, change collection: A to collection: A[B]
  result = newTable[C, B]()
  for item in collection:
    result[index(item)] = item

# ------------------------------ ordered table ------------------------------

type
  OrderedKeyValuePair[A, B] = tuple[
    hcode: Hash, next: int, key: A, val: B]
  OrderedKeyValuePairSeq[A, B] = seq[OrderedKeyValuePair[A, B]]
  OrderedTable* [A, B] = object ## table that remembers insertion order
    data: OrderedKeyValuePairSeq[A, B]
    counter, first, last: int
  OrderedTableRef*[A, B] = ref OrderedTable[A, B]

{.deprecated: [TOrderedTable: OrderedTable, POrderedTable: OrderedTableRef].}

proc len*[A, B](t: OrderedTable[A, B]): int {.inline.} =
  ## returns the number of keys in `t`.
  result = t.counter

template forAllOrderedPairs(yieldStmt: stmt) {.dirty, immediate.} =
  var h = t.first
  while h >= 0:
    var nxt = t.data[h].next
    if isFilled(t.data[h].hcode): yieldStmt
    h = nxt

iterator pairs*[A, B](t: OrderedTable[A, B]): (A, B) =
  ## iterates over any (key, value) pair in the table `t` in insertion
  ## order.
  forAllOrderedPairs:
    yield (t.data[h].key, t.data[h].val)

iterator mpairs*[A, B](t: var OrderedTable[A, B]): (A, var B) =
  ## iterates over any (key, value) pair in the table `t` in insertion
  ## order. The values can be modified.
  forAllOrderedPairs:
    yield (t.data[h].key, t.data[h].val)

iterator keys*[A, B](t: OrderedTable[A, B]): A =
  ## iterates over any key in the table `t` in insertion order.
  forAllOrderedPairs:
    yield t.data[h].key

iterator values*[A, B](t: OrderedTable[A, B]): B =
  ## iterates over any value in the table `t` in insertion order.
  forAllOrderedPairs:
    yield t.data[h].val

iterator mvalues*[A, B](t: var OrderedTable[A, B]): var B =
  ## iterates over any value in the table `t` in insertion order. The values
  ## can be modified.
  forAllOrderedPairs:
    yield t.data[h].val

proc rawGetKnownHC[A, B](t: OrderedTable[A, B], key: A, hc: Hash): int =
  rawGetKnownHCImpl()

proc rawGetDeep[A, B](t: OrderedTable[A, B], key: A, hc: var Hash): int {.inline.} =
  rawGetDeepImpl()

proc rawGet[A, B](t: OrderedTable[A, B], key: A, hc: var Hash): int =
  rawGetImpl()

proc `[]`*[A, B](t: OrderedTable[A, B], key: A): B {.deprecatedGet.} =
  ## retrieves the value at ``t[key]``. If `key` is not in `t`, the
  ## ``KeyError`` exception is raised. One can check with ``hasKey`` whether
  ## the key exists.
  get(t, key)

proc `[]`*[A, B](t: var OrderedTable[A, B], key: A): var B{.deprecatedGet.} =
  ## retrieves the value at ``t[key]``. The value can be modified.
  ## If `key` is not in `t`, the ``KeyError`` exception is raised.
  get(t, key)

proc mget*[A, B](t: var OrderedTable[A, B], key: A): var B {.deprecated.} =
  ## retrieves the value at ``t[key]``. The value can be modified.
  ## If `key` is not in `t`, the ``KeyError`` exception is raised.
  ## Use ```[]``` instead.
  get(t, key)

proc getOrDefault*[A, B](t: OrderedTable[A, B], key: A): B =
  getOrDefaultImpl(t, key)


proc hasKey*[A, B](t: OrderedTable[A, B], key: A): bool =
  ## returns true iff `key` is in the table `t`.
  var hc: Hash
  result = rawGet(t, key, hc) >= 0

proc contains*[A, B](t: OrderedTable[A, B], key: A): bool =
  ## alias of `hasKey` for use with the `in` operator.
  return hasKey[A, B](t, key)

proc rawInsert[A, B](t: var OrderedTable[A, B],
                     data: var OrderedKeyValuePairSeq[A, B],
                     key: A, val: B, hc: Hash, h: Hash) =
  rawInsertImpl()
  data[h].next = -1
  if t.first < 0: t.first = h
  if t.last >= 0: data[t.last].next = h
  t.last = h

proc enlarge[A, B](t: var OrderedTable[A, B]) =
  var n: OrderedKeyValuePairSeq[A, B]
  newSeq(n, len(t.data) * growthFactor)
  var h = t.first
  t.first = -1
  t.last = -1
  swap(t.data, n)
  while h >= 0:
    var nxt = n[h].next
    if isFilled(n[h].hcode):
      var j = -1 - rawGetKnownHC(t, n[h].key, n[h].hcode)
      rawInsert(t, t.data, n[h].key, n[h].val, n[h].hcode, j)
    h = nxt

proc `[]=`*[A, B](t: var OrderedTable[A, B], key: A, val: B) =
  ## puts a (key, value)-pair into `t`.
  putImpl(enlarge)

proc add*[A, B](t: var OrderedTable[A, B], key: A, val: B) =
  ## puts a new (key, value)-pair into `t` even if ``t[key]`` already exists.
  addImpl(enlarge)

proc mgetOrPut*[A, B](t: var OrderedTable[A, B], key: A, val: B): var B =
  ## retrieves value at ``t[key]`` or puts ``value`` if not present, either way
  ## returning a value which can be modified.
  mgetOrPutImpl(enlarge)

proc hasKeyOrPut*[A, B](t: var OrderedTable[A, B], key: A, val: B): bool =
  ## returns true iff `key` is in the table, otherwise inserts `value`.
  hasKeyOrPutImpl(enlarge)

proc initOrderedTable*[A, B](initialSize=64): OrderedTable[A, B] =
  ## creates a new ordered hash table that is empty.
  ##
  ## `initialSize` needs to be a power of two. If you need to accept runtime
  ## values for this you could use the ``nextPowerOfTwo`` proc from the
  ## `math <math.html>`_ module or the ``rightSize`` proc from this module.
  assert isPowerOfTwo(initialSize)
  result.counter = 0
  result.first = -1
  result.last = -1
  newSeq(result.data, initialSize)

proc toOrderedTable*[A, B](pairs: openArray[(A,
                           B)]): OrderedTable[A, B] =
  ## creates a new ordered hash table that contains the given `pairs`.
  result = initOrderedTable[A, B](rightSize(pairs.len))
  for key, val in items(pairs): result[key] = val

proc `$`*[A, B](t: OrderedTable[A, B]): string =
  ## The `$` operator for ordered hash tables.
  dollarImpl()

proc sort*[A, B](t: var OrderedTable[A, B],
                 cmp: proc (x,y: (A, B)): int) =
  ## sorts `t` according to `cmp`. This modifies the internal list
  ## that kept the insertion order, so insertion order is lost after this
  ## call but key lookup and insertions remain possible after `sort` (in
  ## contrast to the `sort` for count tables).
  var list = t.first
  var
    p, q, e, tail, oldhead: int
    nmerges, psize, qsize, i: int
  if t.counter == 0: return
  var insize = 1
  while true:
    p = list; oldhead = list
    list = -1; tail = -1; nmerges = 0
    while p >= 0:
      inc(nmerges)
      q = p
      psize = 0
      i = 0
      while i < insize:
        inc(psize)
        q = t.data[q].next
        if q < 0: break
        inc(i)
      qsize = insize
      while psize > 0 or (qsize > 0 and q >= 0):
        if psize == 0:
          e = q; q = t.data[q].next; dec(qsize)
        elif qsize == 0 or q < 0:
          e = p; p = t.data[p].next; dec(psize)
        elif cmp((t.data[p].key, t.data[p].val),
                 (t.data[q].key, t.data[q].val)) <= 0:
          e = p; p = t.data[p].next; dec(psize)
        else:
          e = q; q = t.data[q].next; dec(qsize)
        if tail >= 0: t.data[tail].next = e
        else: list = e
        tail = e
      p = q
    t.data[tail].next = -1
    if nmerges <= 1: break
    insize = insize * 2
  t.first = list
  t.last = tail

proc len*[A, B](t: OrderedTableRef[A, B]): int {.inline.} =
  ## returns the number of keys in `t`.
  result = t.counter

template forAllOrderedPairs(yieldStmt: stmt) {.dirty, immediate.} =
  var h = t.first
  while h >= 0:
    var nxt = t.data[h].next
    if isFilled(t.data[h].hcode): yieldStmt
    h = nxt

iterator pairs*[A, B](t: OrderedTableRef[A, B]): (A, B) =
  ## iterates over any (key, value) pair in the table `t` in insertion
  ## order.
  forAllOrderedPairs:
    yield (t.data[h].key, t.data[h].val)

iterator mpairs*[A, B](t: OrderedTableRef[A, B]): (A, var B) =
  ## iterates over any (key, value) pair in the table `t` in insertion
  ## order. The values can be modified.
  forAllOrderedPairs:
    yield (t.data[h].key, t.data[h].val)

iterator keys*[A, B](t: OrderedTableRef[A, B]): A =
  ## iterates over any key in the table `t` in insertion order.
  forAllOrderedPairs:
    yield t.data[h].key

iterator values*[A, B](t: OrderedTableRef[A, B]): B =
  ## iterates over any value in the table `t` in insertion order.
  forAllOrderedPairs:
    yield t.data[h].val

iterator mvalues*[A, B](t: OrderedTableRef[A, B]): var B =
  ## iterates over any value in the table `t` in insertion order. The values
  ## can be modified.
  forAllOrderedPairs:
    yield t.data[h].val

proc `[]`*[A, B](t: OrderedTableRef[A, B], key: A): var B =
  ## retrieves the value at ``t[key]``. If `key` is not in `t`, the
  ## ``KeyError`` exception is raised. One can check with ``hasKey`` whether
  ## the key exists.
  result = t[][key]

proc mget*[A, B](t: OrderedTableRef[A, B], key: A): var B {.deprecated.} =
  ## retrieves the value at ``t[key]``. The value can be modified.
  ## If `key` is not in `t`, the ``KeyError`` exception is raised.
  ## Use ```[]``` instead.
  result = t[][key]

proc getOrDefault*[A, B](t: OrderedTableRef[A, B], key: A): B =
  getOrDefault(t[], key)

proc mgetOrPut*[A, B](t: OrderedTableRef[A, B], key: A, val: B): var B =
  ## retrieves value at ``t[key]`` or puts ``val`` if not present, either way
  ## returning a value which can be modified.
  result = t[].mgetOrPut(key, val)

proc hasKeyOrPut*[A, B](t: var OrderedTableRef[A, B], key: A, val: B): bool =
  ## returns true iff `key` is in the table, otherwise inserts `val`.
  result = t[].hasKeyOrPut(key, val)

proc hasKey*[A, B](t: OrderedTableRef[A, B], key: A): bool =
  ## returns true iff `key` is in the table `t`.
  result = t[].hasKey(key)

proc contains*[A, B](t: OrderedTableRef[A, B], key: A): bool =
  ## alias of `hasKey` for use with the `in` operator.
  return hasKey[A, B](t, key)

proc `[]=`*[A, B](t: OrderedTableRef[A, B], key: A, val: B) =
  ## puts a (key, value)-pair into `t`.
  t[][key] = val

proc add*[A, B](t: OrderedTableRef[A, B], key: A, val: B) =
  ## puts a new (key, value)-pair into `t` even if ``t[key]`` already exists.
  t[].add(key, val)

proc newOrderedTable*[A, B](initialSize=64): OrderedTableRef[A, B] =
  ## creates a new ordered hash table that is empty.
  ##
  ## `initialSize` needs to be a power of two. If you need to accept runtime
  ## values for this you could use the ``nextPowerOfTwo`` proc from the
  ## `math <math.html>`_ module or the ``rightSize`` proc from this module.
  new(result)
  result[] = initOrderedTable[A, B]()

proc newOrderedTable*[A, B](pairs: openArray[(A, B)]): OrderedTableRef[A, B] =
  ## creates a new ordered hash table that contains the given `pairs`.
  result = newOrderedTable[A, B](rightSize(pairs.len))
  for key, val in items(pairs): result[key] = val

proc `$`*[A, B](t: OrderedTableRef[A, B]): string =
  ## The `$` operator for ordered hash tables.
  dollarImpl()

proc sort*[A, B](t: OrderedTableRef[A, B],
                 cmp: proc (x,y: (A, B)): int) =
  ## sorts `t` according to `cmp`. This modifies the internal list
  ## that kept the insertion order, so insertion order is lost after this
  ## call but key lookup and insertions remain possible after `sort` (in
  ## contrast to the `sort` for count tables).
  t[].sort(cmp)

# ------------------------------ count tables -------------------------------

type
  CountTable* [
      A] = object ## table that counts the number of each key
    data: seq[tuple[key: A, val: int]]
    counter: int
  CountTableRef*[A] = ref CountTable[A]

{.deprecated: [TCountTable: CountTable, PCountTable: CountTableRef].}

proc len*[A](t: CountTable[A]): int =
  ## returns the number of keys in `t`.
  result = t.counter

iterator pairs*[A](t: CountTable[A]): (A, int) =
  ## iterates over any (key, value) pair in the table `t`.
  for h in 0..high(t.data):
    if t.data[h].val != 0: yield (t.data[h].key, t.data[h].val)

iterator mpairs*[A](t: var CountTable[A]): (A, var int) =
  ## iterates over any (key, value) pair in the table `t`. The values can
  ## be modified.
  for h in 0..high(t.data):
    if t.data[h].val != 0: yield (t.data[h].key, t.data[h].val)

iterator keys*[A](t: CountTable[A]): A =
  ## iterates over any key in the table `t`.
  for h in 0..high(t.data):
    if t.data[h].val != 0: yield t.data[h].key

iterator values*[A](t: CountTable[A]): int =
  ## iterates over any value in the table `t`.
  for h in 0..high(t.data):
    if t.data[h].val != 0: yield t.data[h].val

iterator mvalues*[A](t: CountTable[A]): var int =
  ## iterates over any value in the table `t`. The values can be modified.
  for h in 0..high(t.data):
    if t.data[h].val != 0: yield t.data[h].val

proc rawGet[A](t: CountTable[A], key: A): int =
  var h: Hash = hash(key) and high(t.data) # start with real hash value
  while t.data[h].val != 0:
    if t.data[h].key == key: return h
    h = nextTry(h, high(t.data))
  result = -1 - h                   # < 0 => MISSING; insert idx = -1 - result

template ctget(t, key: untyped): untyped {.immediate.} =
  var index = rawGet(t, key)
  if index >= 0: result = t.data[index].val
  else:
    when compiles($key):
      raise newException(KeyError, "key not found: " & $key)
    else:
      raise newException(KeyError, "key not found")

proc `[]`*[A](t: CountTable[A], key: A): int {.deprecatedGet.} =
  ## retrieves the value at ``t[key]``. If `key` is not in `t`,
  ## the ``KeyError`` exception is raised. One can check with ``hasKey``
  ## whether the key exists.
  ctget(t, key)

proc `[]`*[A](t: var CountTable[A], key: A): var int {.deprecatedGet.} =
  ## retrieves the value at ``t[key]``. The value can be modified.
  ## If `key` is not in `t`, the ``KeyError`` exception is raised.
  ctget(t, key)

proc mget*[A](t: var CountTable[A], key: A): var int {.deprecated.} =
  ## retrieves the value at ``t[key]``. The value can be modified.
  ## If `key` is not in `t`, the ``KeyError`` exception is raised.
  ## Use ```[]``` instead.
  ctget(t, key)

proc getOrDefault*[A](t: CountTable[A], key: A): int =
  var index = rawGet(t, key)
  if index >= 0: result = t.data[index].val

proc hasKey*[A](t: CountTable[A], key: A): bool =
  ## returns true iff `key` is in the table `t`.
  result = rawGet(t, key) >= 0

proc contains*[A](t: CountTable[A], key: A): bool =
  ## alias of `hasKey` for use with the `in` operator.
  return hasKey[A](t, key)

proc rawInsert[A](t: CountTable[A], data: var seq[tuple[key: A, val: int]],
                  key: A, val: int) =
  var h: Hash = hash(key) and high(data)
  while data[h].val != 0: h = nextTry(h, high(data))
  data[h].key = key
  data[h].val = val

proc enlarge[A](t: var CountTable[A]) =
  var n: seq[tuple[key: A, val: int]]
  newSeq(n, len(t.data) * growthFactor)
  for i in countup(0, high(t.data)):
    if t.data[i].val != 0: rawInsert(t, n, t.data[i].key, t.data[i].val)
  swap(t.data, n)

proc `[]=`*[A](t: var CountTable[A], key: A, val: int) =
  ## puts a (key, value)-pair into `t`.
  assert val > 0
  var h = rawGet(t, key)
  if h >= 0:
    t.data[h].val = val
  else:
    if mustRehash(len(t.data), t.counter): enlarge(t)
    rawInsert(t, t.data, key, val)
    inc(t.counter)
    #h = -1 - h
    #t.data[h].key = key
    #t.data[h].val = val

proc initCountTable*[A](initialSize=64): CountTable[A] =
  ## creates a new count table that is empty.
  ##
  ## `initialSize` needs to be a power of two. If you need to accept runtime
  ## values for this you could use the ``nextPowerOfTwo`` proc from the
  ## `math <math.html>`_ module or the ``rightSize`` proc in this module.
  assert isPowerOfTwo(initialSize)
  result.counter = 0
  newSeq(result.data, initialSize)

proc toCountTable*[A](keys: openArray[A]): CountTable[A] =
  ## creates a new count table with every key in `keys` having a count of 1.
  result = initCountTable[A](rightSize(keys.len))
  for key in items(keys): result[key] = 1

proc `$`*[A](t: CountTable[A]): string =
  ## The `$` operator for count tables.
  dollarImpl()

proc inc*[A](t: var CountTable[A], key: A, val = 1) =
  ## increments `t[key]` by `val`.
  var index = rawGet(t, key)
  if index >= 0:
    inc(t.data[index].val, val)
  else:
    if mustRehash(len(t.data), t.counter): enlarge(t)
    rawInsert(t, t.data, key, val)
    inc(t.counter)

proc smallest*[A](t: CountTable[A]): tuple[key: A, val: int] =
  ## returns the largest (key,val)-pair. Efficiency: O(n)
  assert t.len > 0
  var minIdx = 0
  for h in 1..high(t.data):
    if t.data[h].val > 0 and t.data[minIdx].val > t.data[h].val: minIdx = h
  result.key = t.data[minIdx].key
  result.val = t.data[minIdx].val

proc largest*[A](t: CountTable[A]): tuple[key: A, val: int] =
  ## returns the (key,val)-pair with the largest `val`. Efficiency: O(n)
  assert t.len > 0
  var maxIdx = 0
  for h in 1..high(t.data):
    if t.data[maxIdx].val < t.data[h].val: maxIdx = h
  result.key = t.data[maxIdx].key
  result.val = t.data[maxIdx].val

proc sort*[A](t: var CountTable[A]) =
  ## sorts the count table so that the entry with the highest counter comes
  ## first. This is destructive! You must not modify `t` afterwards!
  ## You can use the iterators `pairs`,  `keys`, and `values` to iterate over
  ## `t` in the sorted order.

  # we use shellsort here; fast enough and simple
  var h = 1
  while true:
    h = 3 * h + 1
    if h >= high(t.data): break
  while true:
    h = h div 3
    for i in countup(h, high(t.data)):
      var j = i
      while t.data[j-h].val <= t.data[j].val:
        swap(t.data[j], t.data[j-h])
        j = j-h
        if j < h: break
    if h == 1: break

proc len*[A](t: CountTableRef[A]): int =
  ## returns the number of keys in `t`.
  result = t.counter

iterator pairs*[A](t: CountTableRef[A]): (A, int) =
  ## iterates over any (key, value) pair in the table `t`.
  for h in 0..high(t.data):
    if t.data[h].val != 0: yield (t.data[h].key, t.data[h].val)

iterator mpairs*[A](t: CountTableRef[A]): (A, var int) =
  ## iterates over any (key, value) pair in the table `t`. The values can
  ## be modified.
  for h in 0..high(t.data):
    if t.data[h].val != 0: yield (t.data[h].key, t.data[h].val)

iterator keys*[A](t: CountTableRef[A]): A =
  ## iterates over any key in the table `t`.
  for h in 0..high(t.data):
    if t.data[h].val != 0: yield t.data[h].key

iterator values*[A](t: CountTableRef[A]): int =
  ## iterates over any value in the table `t`.
  for h in 0..high(t.data):
    if t.data[h].val != 0: yield t.data[h].val

iterator mvalues*[A](t: CountTableRef[A]): var int =
  ## iterates over any value in the table `t`. The values can be modified.
  for h in 0..high(t.data):
    if t.data[h].val != 0: yield t.data[h].val

proc `[]`*[A](t: CountTableRef[A], key: A): var int {.deprecatedGet.} =
  ## retrieves the value at ``t[key]``. The value can be modified.
  ## If `key` is not in `t`, the ``KeyError`` exception is raised.
  result = t[][key]

proc mget*[A](t: CountTableRef[A], key: A): var int {.deprecated.} =
  ## retrieves the value at ``t[key]``. The value can be modified.
  ## If `key` is not in `t`, the ``KeyError`` exception is raised.
  ## Use ```[]``` instead.
  result = t[][key]

proc getOrDefault*[A](t: CountTableRef[A], key: A): int =
  getOrDefaultImpl(t, key)

proc hasKey*[A](t: CountTableRef[A], key: A): bool =
  ## returns true iff `key` is in the table `t`.
  result = t[].hasKey(key)

proc contains*[A](t: CountTableRef[A], key: A): bool =
  ## alias of `hasKey` for use with the `in` operator.
  return hasKey[A](t, key)

proc `[]=`*[A](t: CountTableRef[A], key: A, val: int) =
  ## puts a (key, value)-pair into `t`. `val` has to be positive.
  assert val > 0
  t[][key] = val

proc newCountTable*[A](initialSize=64): CountTableRef[A] =
  ## creates a new count table that is empty.
  ##
  ## `initialSize` needs to be a power of two. If you need to accept runtime
  ## values for this you could use the ``nextPowerOfTwo`` proc from the
  ## `math <math.html>`_ module or the ``rightSize`` method in this module.
  new(result)
  result[] = initCountTable[A](initialSize)

proc newCountTable*[A](keys: openArray[A]): CountTableRef[A] =
  ## creates a new count table with every key in `keys` having a count of 1.
  result = newCountTable[A](rightSize(keys.len))
  for key in items(keys): result[key] = 1

proc `$`*[A](t: CountTableRef[A]): string =
  ## The `$` operator for count tables.
  dollarImpl()

proc inc*[A](t: CountTableRef[A], key: A, val = 1) =
  ## increments `t[key]` by `val`.
  t[].inc(key, val)

proc smallest*[A](t: CountTableRef[A]): (A, int) =
  ## returns the largest (key,val)-pair. Efficiency: O(n)
  t[].smallest

proc largest*[A](t: CountTableRef[A]): (A, int) =
  ## returns the (key,val)-pair with the largest `val`. Efficiency: O(n)
  t[].largest

proc sort*[A](t: CountTableRef[A]) =
  ## sorts the count table so that the entry with the highest counter comes
  ## first. This is destructive! You must not modify `t` afterwards!
  ## You can use the iterators `pairs`,  `keys`, and `values` to iterate over
  ## `t` in the sorted order.
  t[].sort

proc merge*[A](s: var CountTable[A], t: CountTable[A]) =
  ## merges the second table into the first one
  for key, value in t:
    s.inc(key, value)

proc merge*[A](s, t: CountTable[A]): CountTable[A] =
  ## merges the two tables into a new one
  result = initCountTable[A](nextPowerOfTwo(max(s.len, t.len)))
  for table in @[s, t]:
    for key, value in table:
      result.inc(key, value)

proc merge*[A](s, t: CountTableRef[A]) =
  ## merges the second table into the first one
  s[].merge(t[])

when isMainModule:
  type
    Person = object
      firstName, lastName: string

  proc hash(x: Person): Hash =
    ## Piggyback on the already available string hash proc.
    ##
    ## Without this proc nothing works!
    result = x.firstName.hash !& x.lastName.hash
    result = !$result

  var
    salaries = initTable[Person, int]()
    p1, p2: Person
  p1.firstName = "Jon"
  p1.lastName = "Ross"
  salaries[p1] = 30_000
  p2.firstName = "소진"
  p2.lastName = "박"
  salaries[p2] = 45_000
  var
    s2 = initOrderedTable[Person, int]()
    s3 = initCountTable[Person]()
  s2[p1] = 30_000
  s2[p2] = 45_000
  s3[p1] = 30_000
  s3[p2] = 45_000

  var
    t1 = initCountTable[string]()
    t2 = initCountTable[string]()
  t1.inc("foo")
  t1.inc("bar", 2)
  t1.inc("baz", 3)
  t2.inc("foo", 4)
  t2.inc("bar")
  t2.inc("baz", 11)
  merge(t1, t2)
  assert(t1["foo"] == 5)
  assert(t1["bar"] == 3)
  assert(t1["baz"] == 14)

  let
    t1r = newCountTable[string]()
    t2r = newCountTable[string]()
  t1r.inc("foo")
  t1r.inc("bar", 2)
  t1r.inc("baz", 3)
  t2r.inc("foo", 4)
  t2r.inc("bar")
  t2r.inc("baz", 11)
  merge(t1r, t2r)
  assert(t1r["foo"] == 5)
  assert(t1r["bar"] == 3)
  assert(t1r["baz"] == 14)

  var
    t1l = initCountTable[string]()
    t2l = initCountTable[string]()
  t1l.inc("foo")
  t1l.inc("bar", 2)
  t1l.inc("baz", 3)
  t2l.inc("foo", 4)
  t2l.inc("bar")
  t2l.inc("baz", 11)
  let
    t1merging = t1l
    t2merging = t2l
  let merged = merge(t1merging, t2merging)
  assert(merged["foo"] == 5)
  assert(merged["bar"] == 3)
  assert(merged["baz"] == 14)

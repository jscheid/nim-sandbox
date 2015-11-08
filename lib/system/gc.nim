#
#
#            Nim's Runtime Library
#        (c) Copyright 2015 Andreas Rumpf
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.
#

#            Garbage Collector
#
# The basic algorithm is *Deferred Reference Counting* with cycle detection.
# This is achieved by combining a Deutsch-Bobrow garbage collector
# together with Christoper's partial mark-sweep garbage collector.
#
# Special care has been taken to avoid recursion as far as possible to avoid
# stack overflows when traversing deep datastructures. It is well-suited
# for soft real time applications (like games).

when defined(nimCoroutines):
  import arch

{.push profiler:off.}

const
  CycleIncrease = 2 # is a multiplicative increase
  InitialCycleThreshold = 4*1024*1024 # X MB because cycle checking is slow
  ZctThreshold = 500  # we collect garbage if the ZCT's size
                      # reaches this threshold
                      # this seems to be a good value
  withRealTime = defined(useRealtimeGC)
  useMarkForDebug = defined(gcGenerational)
  useBackupGc = false                     # use a simple M&S GC to collect
                                          # cycles instead of the complex
                                          # algorithm

when withRealTime and not declared(getTicks):
  include "system/timers"
when defined(memProfiler):
  proc nimProfile(requestedSize: int) {.benign.}

const
  rcIncrement = 0b1000 # so that lowest 3 bits are not touched
  rcBlack = 0b000  # cell is colored black; in use or free
  rcGray = 0b001   # possible member of a cycle
  rcWhite = 0b010  # member of a garbage cycle
  rcPurple = 0b011 # possible root of a cycle
  ZctFlag = 0b100  # in ZCT
  rcShift = 3      # shift by rcShift to get the reference counter
  colorMask = 0b011
type
  WalkOp = enum
    waMarkGlobal,    # part of the backup/debug mark&sweep
    waMarkPrecise,   # part of the backup/debug mark&sweep
    waZctDecRef, waPush, waCycleDecRef, waMarkGray, waScan, waScanBlack,
    waCollectWhite #, waDebug

  Finalizer {.compilerproc.} = proc (self: pointer) {.nimcall, benign.}
    # A ref type can have a finalizer that is called before the object's
    # storage is freed.

  GcStat {.final, pure.} = object
    stackScans: int          # number of performed stack scans (for statistics)
    cycleCollections: int    # number of performed full collections
    maxThreshold: int        # max threshold that has been set
    maxStackSize: int        # max stack size
    maxStackCells: int       # max stack cells in ``decStack``
    cycleTableSize: int      # max entries in cycle table
    maxPause: int64          # max measured GC pause in nanoseconds

  GcStack {.final.} = object
    prev: ptr GcStack
    next: ptr GcStack
    starts: pointer
    pos: pointer
    maxStackSize: int

  GcHeap {.final, pure.} = object # this contains the zero count and
                                   # non-zero count table
    stack: ptr GcStack
    stackBottom: pointer
    cycleThreshold: int
    when useCellIds:
      idGenerator: int
    zct: CellSeq             # the zero count table
    decStack: CellSeq        # cells in the stack that are to decref again
    cycleRoots: CellSet
    tempStack: CellSeq       # temporary stack for recursion elimination
    recGcLock: int           # prevent recursion via finalizers; no thread lock
    when withRealTime:
      maxPause: Nanos        # max allowed pause in nanoseconds; active if > 0
    region: MemRegion        # garbage collected region
    stat: GcStat
    when useMarkForDebug or useBackupGc:
      marked: CellSet
{.deprecated: [TWalkOp: WalkOp, TFinalizer: Finalizer, TGcHeap: GcHeap,
              TGcStat: GcStat].}
var
  gch {.rtlThreadVar.}: GcHeap

when not defined(useNimRtl):
  instantiateForRegion(gch.region)

template acquire(gch: GcHeap) =
  when hasThreadSupport and hasSharedHeap:
    acquireSys(HeapLock)

template release(gch: GcHeap) =
  when hasThreadSupport and hasSharedHeap:
    releaseSys(HeapLock)

template gcAssert(cond: bool, msg: string) =
  when defined(useGcAssert):
    if not cond:
      echo "[GCASSERT] ", msg
      GC_disable()
      writeStackTrace()
      quit 1

proc addZCT(s: var CellSeq, c: PCell) {.noinline.} =
  if (c.refcount and ZctFlag) == 0:
    c.refcount = c.refcount or ZctFlag
    add(s, c)

proc cellToUsr(cell: PCell): pointer {.inline.} =
  # convert object (=pointer to refcount) to pointer to userdata
  result = cast[pointer](cast[ByteAddress](cell)+%ByteAddress(sizeof(Cell)))

proc usrToCell(usr: pointer): PCell {.inline.} =
  # convert pointer to userdata to object (=pointer to refcount)
  result = cast[PCell](cast[ByteAddress](usr)-%ByteAddress(sizeof(Cell)))

proc canBeCycleRoot(c: PCell): bool {.inline.} =
  result = ntfAcyclic notin c.typ.flags

proc extGetCellType(c: pointer): PNimType {.compilerproc.} =
  # used for code generation concerning debugging
  result = usrToCell(c).typ

proc internRefcount(p: pointer): int {.exportc: "getRefcount".} =
  result = int(usrToCell(p).refcount) shr rcShift

# this that has to equals zero, otherwise we have to round up UnitsPerPage:
when BitsPerPage mod (sizeof(int)*8) != 0:
  {.error: "(BitsPerPage mod BitsPerUnit) should be zero!".}

template color(c): expr = c.refCount and colorMask
template setColor(c, col) =
  when col == rcBlack:
    c.refcount = c.refcount and not colorMask
  else:
    c.refcount = c.refcount and not colorMask or col

proc writeCell(msg: cstring, c: PCell) =
  var kind = -1
  if c.typ != nil: kind = ord(c.typ.kind)
  when leakDetector:
    c_fprintf(c_stdout, "[GC] %s: %p %d rc=%ld from %s(%ld)\n",
              msg, c, kind, c.refcount shr rcShift, c.filename, c.line)
  else:
    c_fprintf(c_stdout, "[GC] %s: %p %d rc=%ld; color=%ld\n",
              msg, c, kind, c.refcount shr rcShift, c.color)

template gcTrace(cell, state: expr): stmt {.immediate.} =
  when traceGC: traceCell(cell, state)

# forward declarations:
proc collectCT(gch: var GcHeap) {.benign.}
proc isOnStack(p: pointer): bool {.noinline, benign.}
proc forAllChildren(cell: PCell, op: WalkOp) {.benign.}
proc doOperation(p: pointer, op: WalkOp) {.benign.}
proc forAllChildrenAux(dest: pointer, mt: PNimType, op: WalkOp) {.benign.}
# we need the prototype here for debugging purposes

when hasThreadSupport and hasSharedHeap:
  template `--`(x: expr): expr = atomicDec(x, rcIncrement) <% rcIncrement
  template `++`(x: expr): stmt = discard atomicInc(x, rcIncrement)
else:
  template `--`(x: expr): expr =
    dec(x, rcIncrement)
    x <% rcIncrement
  template `++`(x: expr): stmt = inc(x, rcIncrement)

proc prepareDealloc(cell: PCell) =
  when useMarkForDebug:
    gcAssert(cell notin gch.marked, "Cell still alive!")
  if cell.typ.finalizer != nil:
    # the finalizer could invoke something that
    # allocates memory; this could trigger a garbage
    # collection. Since we are already collecting we
    # prevend recursive entering here by a lock.
    # XXX: we should set the cell's children to nil!
    inc(gch.recGcLock)
    (cast[Finalizer](cell.typ.finalizer))(cellToUsr(cell))
    dec(gch.recGcLock)

proc rtlAddCycleRoot(c: PCell) {.rtl, inl.} =
  # we MUST access gch as a global here, because this crosses DLL boundaries!
  when hasThreadSupport and hasSharedHeap:
    acquireSys(HeapLock)
  when cycleGC:
    if c.color != rcPurple:
      c.setColor(rcPurple)
      incl(gch.cycleRoots, c)
  when hasThreadSupport and hasSharedHeap:
    releaseSys(HeapLock)

proc rtlAddZCT(c: PCell) {.rtl, inl.} =
  # we MUST access gch as a global here, because this crosses DLL boundaries!
  when hasThreadSupport and hasSharedHeap:
    acquireSys(HeapLock)
  addZCT(gch.zct, c)
  when hasThreadSupport and hasSharedHeap:
    releaseSys(HeapLock)

proc decRef(c: PCell) {.inline.} =
  gcAssert(isAllocatedPtr(gch.region, c), "decRef: interiorPtr")
  gcAssert(c.refcount >=% rcIncrement, "decRef")
  if --c.refcount:
    rtlAddZCT(c)
  elif canbeCycleRoot(c):
    # unfortunately this is necessary here too, because a cycle might just
    # have been broken up and we could recycle it.
    rtlAddCycleRoot(c)
    #writeCell("decRef", c)

proc incRef(c: PCell) {.inline.} =
  gcAssert(isAllocatedPtr(gch.region, c), "incRef: interiorPtr")
  c.refcount = c.refcount +% rcIncrement
  # and not colorMask
  #writeCell("incRef", c)
  if canbeCycleRoot(c):
    rtlAddCycleRoot(c)

proc nimGCref(p: pointer) {.compilerProc, inline.} = incRef(usrToCell(p))
proc nimGCunref(p: pointer) {.compilerProc, inline.} = decRef(usrToCell(p))

proc GC_addCycleRoot*[T](p: ref T) {.inline.} =
  ## adds 'p' to the cycle candidate set for the cycle collector. It is
  ## necessary if you used the 'acyclic' pragma for optimization
  ## purposes and need to break cycles manually.
  rtlAddCycleRoot(usrToCell(cast[pointer](p)))

proc nimGCunrefNoCycle(p: pointer) {.compilerProc, inline.} =
  sysAssert(allocInv(gch.region), "begin nimGCunrefNoCycle")
  var c = usrToCell(p)
  gcAssert(isAllocatedPtr(gch.region, c), "nimGCunrefNoCycle: isAllocatedPtr")
  if --c.refcount:
    rtlAddZCT(c)
    sysAssert(allocInv(gch.region), "end nimGCunrefNoCycle 2")
  sysAssert(allocInv(gch.region), "end nimGCunrefNoCycle 5")

proc asgnRef(dest: PPointer, src: pointer) {.compilerProc, inline.} =
  # the code generator calls this proc!
  gcAssert(not isOnStack(dest), "asgnRef")
  # BUGFIX: first incRef then decRef!
  if src != nil: incRef(usrToCell(src))
  if dest[] != nil: decRef(usrToCell(dest[]))
  dest[] = src

proc asgnRefNoCycle(dest: PPointer, src: pointer) {.compilerProc, inline.} =
  # the code generator calls this proc if it is known at compile time that no
  # cycle is possible.
  if src != nil:
    var c = usrToCell(src)
    ++c.refcount
  if dest[] != nil:
    var c = usrToCell(dest[])
    if --c.refcount:
      rtlAddZCT(c)
  dest[] = src

proc unsureAsgnRef(dest: PPointer, src: pointer) {.compilerProc.} =
  # unsureAsgnRef updates the reference counters only if dest is not on the
  # stack. It is used by the code generator if it cannot decide wether a
  # reference is in the stack or not (this can happen for var parameters).
  if not isOnStack(dest):
    if src != nil: incRef(usrToCell(src))
    # XXX finally use assembler for the stack checking instead!
    # the test for '!= nil' is correct, but I got tired of the segfaults
    # resulting from the crappy stack checking:
    if cast[int](dest[]) >=% PageSize: decRef(usrToCell(dest[]))
  else:
    # can't be an interior pointer if it's a stack location!
    gcAssert(interiorAllocatedPtr(gch.region, dest) == nil,
             "stack loc AND interior pointer")
  dest[] = src

proc initGC() =
  when not defined(useNimRtl):
    when traceGC:
      for i in low(CellState)..high(CellState): init(states[i])
    gch.cycleThreshold = InitialCycleThreshold
    gch.stat.stackScans = 0
    gch.stat.cycleCollections = 0
    gch.stat.maxThreshold = 0
    gch.stat.maxStackSize = 0
    gch.stat.maxStackCells = 0
    gch.stat.cycleTableSize = 0
    # init the rt
    init(gch.zct)
    init(gch.tempStack)
    init(gch.cycleRoots)
    init(gch.decStack)
    when useMarkForDebug or useBackupGc:
      init(gch.marked)

when useMarkForDebug or useBackupGc:
  type
    GlobalMarkerProc = proc () {.nimcall, benign.}
  {.deprecated: [TGlobalMarkerProc: GlobalMarkerProc].}
  var
    globalMarkersLen: int
    globalMarkers: array[0.. 7_000, GlobalMarkerProc]

  proc nimRegisterGlobalMarker(markerProc: GlobalMarkerProc) {.compilerProc.} =
    if globalMarkersLen <= high(globalMarkers):
      globalMarkers[globalMarkersLen] = markerProc
      inc globalMarkersLen
    else:
      echo "[GC] cannot register global variable; too many global variables"
      quit 1

proc cellsetReset(s: var CellSet) =
  deinit(s)
  init(s)

proc forAllSlotsAux(dest: pointer, n: ptr TNimNode, op: WalkOp) {.benign.} =
  var d = cast[ByteAddress](dest)
  case n.kind
  of nkSlot: forAllChildrenAux(cast[pointer](d +% n.offset), n.typ, op)
  of nkList:
    for i in 0..n.len-1:
      # inlined for speed
      if n.sons[i].kind == nkSlot:
        if n.sons[i].typ.kind in {tyRef, tyString, tySequence}:
          doOperation(cast[PPointer](d +% n.sons[i].offset)[], op)
        else:
          forAllChildrenAux(cast[pointer](d +% n.sons[i].offset),
                            n.sons[i].typ, op)
      else:
        forAllSlotsAux(dest, n.sons[i], op)
  of nkCase:
    var m = selectBranch(dest, n)
    if m != nil: forAllSlotsAux(dest, m, op)
  of nkNone: sysAssert(false, "forAllSlotsAux")

proc forAllChildrenAux(dest: pointer, mt: PNimType, op: WalkOp) =
  var d = cast[ByteAddress](dest)
  if dest == nil: return # nothing to do
  if ntfNoRefs notin mt.flags:
    case mt.kind
    of tyRef, tyString, tySequence: # leaf:
      doOperation(cast[PPointer](d)[], op)
    of tyObject, tyTuple:
      forAllSlotsAux(dest, mt.node, op)
    of tyArray, tyArrayConstr, tyOpenArray:
      for i in 0..(mt.size div mt.base.size)-1:
        forAllChildrenAux(cast[pointer](d +% i *% mt.base.size), mt.base, op)
    else: discard

proc forAllChildren(cell: PCell, op: WalkOp) =
  gcAssert(cell != nil, "forAllChildren: 1")
  gcAssert(isAllocatedPtr(gch.region, cell), "forAllChildren: 2")
  gcAssert(cell.typ != nil, "forAllChildren: 3")
  gcAssert cell.typ.kind in {tyRef, tySequence, tyString}, "forAllChildren: 4"
  let marker = cell.typ.marker
  if marker != nil:
    marker(cellToUsr(cell), op.int)
  else:
    case cell.typ.kind
    of tyRef: # common case
      forAllChildrenAux(cellToUsr(cell), cell.typ.base, op)
    of tySequence:
      var d = cast[ByteAddress](cellToUsr(cell))
      var s = cast[PGenericSeq](d)
      if s != nil:
        for i in 0..s.len-1:
          forAllChildrenAux(cast[pointer](d +% i *% cell.typ.base.size +%
            GenericSeqSize), cell.typ.base, op)
    else: discard

proc addNewObjToZCT(res: PCell, gch: var GcHeap) {.inline.} =
  # we check the last 8 entries (cache line) for a slot that could be reused.
  # In 63% of all cases we succeed here! But we have to optimize the heck
  # out of this small linear search so that ``newObj`` is not slowed down.
  #
  # Slots to try          cache hit
  # 1                     32%
  # 4                     59%
  # 8                     63%
  # 16                    66%
  # all slots             68%
  var L = gch.zct.len
  var d = gch.zct.d
  when true:
    # loop unrolled for performance:
    template replaceZctEntry(i: expr) =
      c = d[i]
      if c.refcount >=% rcIncrement:
        c.refcount = c.refcount and not ZctFlag
        d[i] = res
        return
    if L > 8:
      var c: PCell
      replaceZctEntry(L-1)
      replaceZctEntry(L-2)
      replaceZctEntry(L-3)
      replaceZctEntry(L-4)
      replaceZctEntry(L-5)
      replaceZctEntry(L-6)
      replaceZctEntry(L-7)
      replaceZctEntry(L-8)
      add(gch.zct, res)
    else:
      d[L] = res
      inc(gch.zct.len)
  else:
    for i in countdown(L-1, max(0, L-8)):
      var c = d[i]
      if c.refcount >=% rcIncrement:
        c.refcount = c.refcount and not ZctFlag
        d[i] = res
        return
    add(gch.zct, res)

{.push stackTrace: off, profiler:off.}
proc gcInvariant*() =
  sysAssert(allocInv(gch.region), "injected")
  when declared(markForDebug):
    markForDebug(gch)
{.pop.}

proc rawNewObj(typ: PNimType, size: int, gch: var GcHeap): pointer =
  # generates a new object and sets its reference counter to 0
  sysAssert(allocInv(gch.region), "rawNewObj begin")
  acquire(gch)
  gcAssert(typ.kind in {tyRef, tyString, tySequence}, "newObj: 1")
  collectCT(gch)
  var res = cast[PCell](rawAlloc(gch.region, size + sizeof(Cell)))
  gcAssert((cast[ByteAddress](res) and (MemAlign-1)) == 0, "newObj: 2")
  # now it is buffered in the ZCT
  res.typ = typ
  when leakDetector and not hasThreadSupport:
    if framePtr != nil and framePtr.prev != nil:
      res.filename = framePtr.prev.filename
      res.line = framePtr.prev.line
  # refcount is zero, color is black, but mark it to be in the ZCT
  res.refcount = ZctFlag
  sysAssert(isAllocatedPtr(gch.region, res), "newObj: 3")
  # its refcount is zero, so add it to the ZCT:
  addNewObjToZCT(res, gch)
  when logGC: writeCell("new cell", res)
  gcTrace(res, csAllocated)
  release(gch)
  when useCellIds:
    inc gch.idGenerator
    res.id = gch.idGenerator
  result = cellToUsr(res)
  sysAssert(allocInv(gch.region), "rawNewObj end")

{.pop.}

proc newObjNoInit(typ: PNimType, size: int): pointer {.compilerRtl.} =
  result = rawNewObj(typ, size, gch)
  when defined(memProfiler): nimProfile(size)

proc newObj(typ: PNimType, size: int): pointer {.compilerRtl.} =
  result = rawNewObj(typ, size, gch)
  zeroMem(result, size)
  when defined(memProfiler): nimProfile(size)

proc newSeq(typ: PNimType, len: int): pointer {.compilerRtl.} =
  # `newObj` already uses locks, so no need for them here.
  let size = addInt(mulInt(len, typ.base.size), GenericSeqSize)
  result = newObj(typ, size)
  cast[PGenericSeq](result).len = len
  cast[PGenericSeq](result).reserved = len
  when defined(memProfiler): nimProfile(size)

proc newObjRC1(typ: PNimType, size: int): pointer {.compilerRtl.} =
  # generates a new object and sets its reference counter to 1
  sysAssert(allocInv(gch.region), "newObjRC1 begin")
  acquire(gch)
  gcAssert(typ.kind in {tyRef, tyString, tySequence}, "newObj: 1")
  collectCT(gch)
  sysAssert(allocInv(gch.region), "newObjRC1 after collectCT")

  var res = cast[PCell](rawAlloc(gch.region, size + sizeof(Cell)))
  sysAssert(allocInv(gch.region), "newObjRC1 after rawAlloc")
  sysAssert((cast[ByteAddress](res) and (MemAlign-1)) == 0, "newObj: 2")
  # now it is buffered in the ZCT
  res.typ = typ
  when leakDetector and not hasThreadSupport:
    if framePtr != nil and framePtr.prev != nil:
      res.filename = framePtr.prev.filename
      res.line = framePtr.prev.line
  res.refcount = rcIncrement # refcount is 1
  sysAssert(isAllocatedPtr(gch.region, res), "newObj: 3")
  when logGC: writeCell("new cell", res)
  gcTrace(res, csAllocated)
  release(gch)
  when useCellIds:
    inc gch.idGenerator
    res.id = gch.idGenerator
  result = cellToUsr(res)
  zeroMem(result, size)
  sysAssert(allocInv(gch.region), "newObjRC1 end")
  when defined(memProfiler): nimProfile(size)

proc newSeqRC1(typ: PNimType, len: int): pointer {.compilerRtl.} =
  let size = addInt(mulInt(len, typ.base.size), GenericSeqSize)
  result = newObjRC1(typ, size)
  cast[PGenericSeq](result).len = len
  cast[PGenericSeq](result).reserved = len
  when defined(memProfiler): nimProfile(size)

proc growObj(old: pointer, newsize: int, gch: var GcHeap): pointer =
  acquire(gch)
  collectCT(gch)
  var ol = usrToCell(old)
  sysAssert(ol.typ != nil, "growObj: 1")
  gcAssert(ol.typ.kind in {tyString, tySequence}, "growObj: 2")
  sysAssert(allocInv(gch.region), "growObj begin")

  var res = cast[PCell](rawAlloc(gch.region, newsize + sizeof(Cell)))
  var elemSize = 1
  if ol.typ.kind != tyString: elemSize = ol.typ.base.size

  var oldsize = cast[PGenericSeq](old).len*elemSize + GenericSeqSize
  copyMem(res, ol, oldsize + sizeof(Cell))
  zeroMem(cast[pointer](cast[ByteAddress](res)+% oldsize +% sizeof(Cell)),
          newsize-oldsize)
  sysAssert((cast[ByteAddress](res) and (MemAlign-1)) == 0, "growObj: 3")
  # This can be wrong for intermediate temps that are nevertheless on the
  # heap because of lambda lifting:
  #gcAssert(res.refcount shr rcShift <=% 1, "growObj: 4")
  when logGC:
    writeCell("growObj old cell", ol)
    writeCell("growObj new cell", res)
  gcTrace(ol, csZctFreed)
  gcTrace(res, csAllocated)
  when reallyDealloc:
    sysAssert(allocInv(gch.region), "growObj before dealloc")
    if ol.refcount shr rcShift <=% 1:
      # free immediately to save space:
      if (ol.refcount and ZctFlag) != 0:
        var j = gch.zct.len-1
        var d = gch.zct.d
        while j >= 0:
          if d[j] == ol:
            d[j] = res
            break
          dec(j)
      if canbeCycleRoot(ol): excl(gch.cycleRoots, ol)
      rawDealloc(gch.region, ol)
    else:
      # we split the old refcount in 2 parts. XXX This is still not entirely
      # correct if the pointer that receives growObj's result is on the stack.
      # A better fix would be to emit the location specific write barrier for
      # 'growObj', but this is lost of more work and who knows what new problems
      # this would create.
      res.refcount = rcIncrement
      decRef(ol)
  else:
    sysAssert(ol.typ != nil, "growObj: 5")
    zeroMem(ol, sizeof(Cell))
  release(gch)
  when useCellIds:
    inc gch.idGenerator
    res.id = gch.idGenerator
  result = cellToUsr(res)
  sysAssert(allocInv(gch.region), "growObj end")
  when defined(memProfiler): nimProfile(newsize-oldsize)

proc growObj(old: pointer, newsize: int): pointer {.rtl.} =
  result = growObj(old, newsize, gch)

{.push profiler:off.}

# ---------------- cycle collector -------------------------------------------

proc freeCyclicCell(gch: var GcHeap, c: PCell) =
  prepareDealloc(c)
  gcTrace(c, csCycFreed)
  when logGC: writeCell("cycle collector dealloc cell", c)
  when reallyDealloc:
    sysAssert(allocInv(gch.region), "free cyclic cell")
    rawDealloc(gch.region, c)
  else:
    gcAssert(c.typ != nil, "freeCyclicCell")
    zeroMem(c, sizeof(Cell))

proc markGray(s: PCell) =
  if s.color != rcGray:
    setColor(s, rcGray)
    forAllChildren(s, waMarkGray)

proc scanBlack(s: PCell) =
  s.setColor(rcBlack)
  forAllChildren(s, waScanBlack)

proc scan(s: PCell) =
  if s.color == rcGray:
    if s.refcount >=% rcIncrement:
      scanBlack(s)
    else:
      s.setColor(rcWhite)
      forAllChildren(s, waScan)

proc collectWhite(s: PCell) =
  # This is a hacky way to deal with the following problem (bug #1796)
  # Consider this content in cycleRoots:
  #   x -> a; y -> a  where 'a' is an acyclic object so not included in
  # cycleRoots itself. Then 'collectWhite' used to free 'a' twice. The
  # 'isAllocatedPtr' check prevents this. This also means we do not need
  # to query 's notin gch.cycleRoots' at all.
  if isAllocatedPtr(gch.region, s) and s.color == rcWhite:
    s.setColor(rcBlack)
    forAllChildren(s, waCollectWhite)
    freeCyclicCell(gch, s)

proc markRoots(gch: var GcHeap) =
  var tabSize = 0
  for s in elements(gch.cycleRoots):
    #writeCell("markRoot", s)
    inc tabSize
    if s.color == rcPurple and s.refcount >=% rcIncrement:
      markGray(s)
    else:
      excl(gch.cycleRoots, s)
      # (s.color == rcBlack and rc == 0) as 1 condition:
      if s.refcount == 0:
        freeCyclicCell(gch, s)
  gch.stat.cycleTableSize = max(gch.stat.cycleTableSize, tabSize)

when useBackupGc:
  proc sweep(gch: var GcHeap) =
    for x in allObjects(gch.region):
      if isCell(x):
        # cast to PCell is correct here:
        var c = cast[PCell](x)
        if c notin gch.marked: freeCyclicCell(gch, c)

when useMarkForDebug or useBackupGc:
  proc markS(gch: var GcHeap, c: PCell) =
    incl(gch.marked, c)
    gcAssert gch.tempStack.len == 0, "stack not empty!"
    forAllChildren(c, waMarkPrecise)
    while gch.tempStack.len > 0:
      dec gch.tempStack.len
      var d = gch.tempStack.d[gch.tempStack.len]
      if not containsOrIncl(gch.marked, d):
        forAllChildren(d, waMarkPrecise)

  proc markGlobals(gch: var GcHeap) =
    for i in 0 .. < globalMarkersLen: globalMarkers[i]()

  proc stackMarkS(gch: var GcHeap, p: pointer) {.inline.} =
    # the addresses are not as cells on the stack, so turn them to cells:
    var cell = usrToCell(p)
    var c = cast[TAddress](cell)
    if c >% PageSize:
      # fast check: does it look like a cell?
      var objStart = cast[PCell](interiorAllocatedPtr(gch.region, cell))
      if objStart != nil:
        markS(gch, objStart)

when logGC:
  var
    cycleCheckA: array[100, PCell]
    cycleCheckALen = 0

  proc alreadySeen(c: PCell): bool =
    for i in 0 .. <cycleCheckALen:
      if cycleCheckA[i] == c: return true
    if cycleCheckALen == len(cycleCheckA):
      gcAssert(false, "cycle detection overflow")
      quit 1
    cycleCheckA[cycleCheckALen] = c
    inc cycleCheckALen

  proc debugGraph(s: PCell) =
    if alreadySeen(s):
      writeCell("child cell (already seen) ", s)
    else:
      writeCell("cell {", s)
      forAllChildren(s, waDebug)
      c_fprintf(c_stdout, "}\n")

proc doOperation(p: pointer, op: WalkOp) =
  if p == nil: return
  var c: PCell = usrToCell(p)
  gcAssert(c != nil, "doOperation: 1")
  # the 'case' should be faster than function pointers because of easy
  # prediction:
  case op
  of waZctDecRef:
    #if not isAllocatedPtr(gch.region, c):
    #  c_fprintf(c_stdout, "[GC] decref bug: %p", c)
    gcAssert(isAllocatedPtr(gch.region, c), "decRef: waZctDecRef")
    gcAssert(c.refcount >=% rcIncrement, "doOperation 2")
    #c.refcount = c.refcount -% rcIncrement
    when logGC: writeCell("decref (from doOperation)", c)
    decRef(c)
    #if c.refcount <% rcIncrement: addZCT(gch.zct, c)
  of waPush:
    add(gch.tempStack, c)
  of waCycleDecRef:
    gcAssert(c.refcount >=% rcIncrement, "doOperation 3")
    c.refcount = c.refcount -% rcIncrement
  of waMarkGray:
    gcAssert(c.refcount >=% rcIncrement, "waMarkGray")
    c.refcount = c.refcount -% rcIncrement
    markGray(c)
  of waScan: scan(c)
  of waScanBlack:
    c.refcount = c.refcount +% rcIncrement
    if c.color != rcBlack:
      scanBlack(c)
  of waCollectWhite: collectWhite(c)
  of waMarkGlobal:
    when useMarkForDebug or useBackupGc:
      when hasThreadSupport:
        # could point to a cell which we don't own and don't want to touch/trace
        if isAllocatedPtr(gch.region, c):
          markS(gch, c)
      else:
        markS(gch, c)
  of waMarkPrecise:
    when useMarkForDebug or useBackupGc:
      add(gch.tempStack, c)
  #of waDebug: debugGraph(c)

proc nimGCvisit(d: pointer, op: int) {.compilerRtl.} =
  doOperation(d, WalkOp(op))

proc collectZCT(gch: var GcHeap): bool {.benign.}

when useMarkForDebug or useBackupGc:
  proc markStackAndRegistersForSweep(gch: var GcHeap) {.noinline, cdecl,
                                                         benign.}

proc collectRoots(gch: var GcHeap) =
  for s in elements(gch.cycleRoots):
    collectWhite(s)

proc collectCycles(gch: var GcHeap) =
  # ensure the ZCT 'color' is not used:
  while gch.zct.len > 0: discard collectZCT(gch)
  when useBackupGc:
    cellsetReset(gch.marked)
    markStackAndRegistersForSweep(gch)
    markGlobals(gch)
    sweep(gch)
  else:
    markRoots(gch)
    # scanRoots:
    for s in elements(gch.cycleRoots): scan(s)
    collectRoots(gch)

    cellsetReset(gch.cycleRoots)
  # alive cycles need to be kept in 'cycleRoots' if they are referenced
  # from the stack; otherwise the write barrier will add the cycle root again
  # anyway:
  when false:
    var d = gch.decStack.d
    var cycleRootsLen = 0
    for i in 0..gch.decStack.len-1:
      var c = d[i]
      gcAssert isAllocatedPtr(gch.region, c), "addBackStackRoots"
      gcAssert c.refcount >=% rcIncrement, "addBackStackRoots: dead cell"
      if canBeCycleRoot(c):
        #if c notin gch.cycleRoots:
        inc cycleRootsLen
        incl(gch.cycleRoots, c)
      gcAssert c.typ != nil, "addBackStackRoots 2"
    if cycleRootsLen != 0:
      cfprintf(cstdout, "cycle roots: %ld\n", cycleRootsLen)

proc gcMark(gch: var GcHeap, p: pointer) {.inline.} =
  # the addresses are not as cells on the stack, so turn them to cells:
  sysAssert(allocInv(gch.region), "gcMark begin")
  var cell = usrToCell(p)
  var c = cast[ByteAddress](cell)
  if c >% PageSize:
    # fast check: does it look like a cell?
    var objStart = cast[PCell](interiorAllocatedPtr(gch.region, cell))
    if objStart != nil:
      # mark the cell:
      objStart.refcount = objStart.refcount +% rcIncrement
      add(gch.decStack, objStart)
    when false:
      if isAllocatedPtr(gch.region, cell):
        sysAssert false, "allocated pointer but not interior?"
        # mark the cell:
        cell.refcount = cell.refcount +% rcIncrement
        add(gch.decStack, cell)
  sysAssert(allocInv(gch.region), "gcMark end")

proc markThreadStacks(gch: var GcHeap) =
  when hasThreadSupport and hasSharedHeap:
    {.error: "not fully implemented".}
    var it = threadList
    while it != nil:
      # mark registers:
      for i in 0 .. high(it.registers): gcMark(gch, it.registers[i])
      var sp = cast[TAddress](it.stackBottom)
      var max = cast[TAddress](it.stackTop)
      # XXX stack direction?
      # XXX unroll this loop:
      while sp <=% max:
        gcMark(gch, cast[ppointer](sp)[])
        sp = sp +% sizeof(pointer)
      it = it.next

include gc_common

proc markStackAndRegisters(gch: var GcHeap) {.noinline, cdecl.} =
  forEachStackSlot(gch, gcMark)

when useMarkForDebug or useBackupGc:
  proc markStackAndRegistersForSweep(gch: var GcHeap) =
    forEachStackSlot(gch, stackMarkS)

proc collectZCT(gch: var GcHeap): bool =
  # Note: Freeing may add child objects to the ZCT! So essentially we do
  # deep freeing, which is bad for incremental operation. In order to
  # avoid a deep stack, we move objects to keep the ZCT small.
  # This is performance critical!
  const workPackage = 100
  var L = addr(gch.zct.len)

  when withRealTime:
    var steps = workPackage
    var t0: Ticks
    if gch.maxPause > 0: t0 = getticks()
  while L[] > 0:
    var c = gch.zct.d[0]
    sysAssert(isAllocatedPtr(gch.region, c), "CollectZCT: isAllocatedPtr")
    # remove from ZCT:
    gcAssert((c.refcount and ZctFlag) == ZctFlag, "collectZCT")

    c.refcount = c.refcount and not ZctFlag
    gch.zct.d[0] = gch.zct.d[L[] - 1]
    dec(L[])
    when withRealTime: dec steps
    if c.refcount <% rcIncrement:
      # It may have a RC > 0, if it is in the hardware stack or
      # it has not been removed yet from the ZCT. This is because
      # ``incref`` does not bother to remove the cell from the ZCT
      # as this might be too slow.
      # In any case, it should be removed from the ZCT. But not
      # freed. **KEEP THIS IN MIND WHEN MAKING THIS INCREMENTAL!**
      when cycleGC:
        if canbeCycleRoot(c): excl(gch.cycleRoots, c)
      when logGC: writeCell("zct dealloc cell", c)
      gcTrace(c, csZctFreed)
      # We are about to free the object, call the finalizer BEFORE its
      # children are deleted as well, because otherwise the finalizer may
      # access invalid memory. This is done by prepareDealloc():
      prepareDealloc(c)
      forAllChildren(c, waZctDecRef)
      when reallyDealloc:
        sysAssert(allocInv(gch.region), "collectZCT: rawDealloc")
        rawDealloc(gch.region, c)
      else:
        sysAssert(c.typ != nil, "collectZCT 2")
        zeroMem(c, sizeof(Cell))
    when withRealTime:
      if steps == 0:
        steps = workPackage
        if gch.maxPause > 0:
          let duration = getticks() - t0
          # the GC's measuring is not accurate and needs some cleanup actions
          # (stack unmarking), so subtract some short amount of time in
          # order to miss deadlines less often:
          if duration >= gch.maxPause - 50_000:
            return false
  result = true

proc unmarkStackAndRegisters(gch: var GcHeap) =
  var d = gch.decStack.d
  for i in 0..gch.decStack.len-1:
    sysAssert isAllocatedPtr(gch.region, d[i]), "unmarkStackAndRegisters"
    decRef(d[i])
    #var c = d[i]
    # XXX no need for an atomic dec here:
    #if --c.refcount:
    #  addZCT(gch.zct, c)
    #sysAssert c.typ != nil, "unmarkStackAndRegisters 2"
  gch.decStack.len = 0

proc collectCTBody(gch: var GcHeap) =
  when withRealTime:
    let t0 = getticks()
  sysAssert(allocInv(gch.region), "collectCT: begin")

  when not defined(nimCoroutines):
    gch.stat.maxStackSize = max(gch.stat.maxStackSize, stackSize())
  sysAssert(gch.decStack.len == 0, "collectCT")
  prepareForInteriorPointerChecking(gch.region)
  markStackAndRegisters(gch)
  markThreadStacks(gch)
  gch.stat.maxStackCells = max(gch.stat.maxStackCells, gch.decStack.len)
  inc(gch.stat.stackScans)
  if collectZCT(gch):
    when cycleGC:
      if getOccupiedMem(gch.region) >= gch.cycleThreshold or alwaysCycleGC:
        collectCycles(gch)
        #discard collectZCT(gch)
        inc(gch.stat.cycleCollections)
        gch.cycleThreshold = max(InitialCycleThreshold, getOccupiedMem() *
                                 CycleIncrease)
        gch.stat.maxThreshold = max(gch.stat.maxThreshold, gch.cycleThreshold)
  unmarkStackAndRegisters(gch)
  sysAssert(allocInv(gch.region), "collectCT: end")

  when withRealTime:
    let duration = getticks() - t0
    gch.stat.maxPause = max(gch.stat.maxPause, duration)
    when defined(reportMissedDeadlines):
      if gch.maxPause > 0 and duration > gch.maxPause:
        c_fprintf(c_stdout, "[GC] missed deadline: %ld\n", duration)

when useMarkForDebug or useBackupGc:
  proc markForDebug(gch: var GcHeap) =
    markStackAndRegistersForSweep(gch)
    markGlobals(gch)

when defined(nimCoroutines):
  proc currentStackSizes(): int =
    for stack in items(gch.stack):
      result = result + stackSize(stack.starts, stack.pos)

proc collectCT(gch: var GcHeap) =
  # stackMarkCosts prevents some pathological behaviour: Stack marking
  # becomes more expensive with large stacks and large stacks mean that
  # cells with RC=0 are more likely to be kept alive by the stack.
  when defined(nimCoroutines):
    let stackMarkCosts = max(currentStackSizes() div (16*sizeof(int)), ZctThreshold)
  else:
    let stackMarkCosts = max(stackSize() div (16*sizeof(int)), ZctThreshold)
  if (gch.zct.len >= stackMarkCosts or (cycleGC and
      getOccupiedMem(gch.region)>=gch.cycleThreshold) or alwaysGC) and
      gch.recGcLock == 0:
    when useMarkForDebug:
      prepareForInteriorPointerChecking(gch.region)
      cellsetReset(gch.marked)
      markForDebug(gch)
    collectCTBody(gch)

when withRealTime:
  proc toNano(x: int): Nanos {.inline.} =
    result = x * 1000

  proc GC_setMaxPause*(MaxPauseInUs: int) =
    gch.maxPause = MaxPauseInUs.toNano

  proc GC_step(gch: var GcHeap, us: int, strongAdvice: bool) =
    acquire(gch)
    gch.maxPause = us.toNano
    if (gch.zct.len >= ZctThreshold or (cycleGC and
        getOccupiedMem(gch.region)>=gch.cycleThreshold) or alwaysGC) or
        strongAdvice:
      collectCTBody(gch)
    release(gch)

  proc GC_step*(us: int, strongAdvice = false) = GC_step(gch, us, strongAdvice)

when not defined(useNimRtl):
  proc GC_disable() =
    when hasThreadSupport and hasSharedHeap:
      discard atomicInc(gch.recGcLock, 1)
    else:
      inc(gch.recGcLock)
  proc GC_enable() =
    if gch.recGcLock > 0:
      when hasThreadSupport and hasSharedHeap:
        discard atomicDec(gch.recGcLock, 1)
      else:
        dec(gch.recGcLock)

  proc GC_setStrategy(strategy: GC_Strategy) =
    discard

  proc GC_enableMarkAndSweep() =
    gch.cycleThreshold = InitialCycleThreshold

  proc GC_disableMarkAndSweep() =
    gch.cycleThreshold = high(gch.cycleThreshold)-1
    # set to the max value to suppress the cycle detector

  proc GC_fullCollect() =
    acquire(gch)
    var oldThreshold = gch.cycleThreshold
    gch.cycleThreshold = 0 # forces cycle collection
    collectCT(gch)
    gch.cycleThreshold = oldThreshold
    release(gch)

  proc GC_getStatistics(): string =
    GC_disable()
    result = "[GC] total memory: " & $(getTotalMem()) & "\n" &
             "[GC] occupied memory: " & $(getOccupiedMem()) & "\n" &
             "[GC] stack scans: " & $gch.stat.stackScans & "\n" &
             "[GC] stack cells: " & $gch.stat.maxStackCells & "\n" &
             "[GC] cycle collections: " & $gch.stat.cycleCollections & "\n" &
             "[GC] max threshold: " & $gch.stat.maxThreshold & "\n" &
             "[GC] zct capacity: " & $gch.zct.cap & "\n" &
             "[GC] max cycle table size: " & $gch.stat.cycleTableSize & "\n" &
             "[GC] max pause time [ms]: " & $(gch.stat.maxPause div 1000_000)
    when defined(nimCoroutines):
      result = result & "[GC] number of stacks: " & $gch.stack.len & "\n"
      for stack in items(gch.stack):
        result = result & "[GC]   stack " & stack.starts.repr & "[GC]     max stack size " & $stack.maxStackSize & "\n"
    else:
      result = result & "[GC] max stack size: " & $gch.stat.maxStackSize & "\n"
    GC_enable()

{.pop.}

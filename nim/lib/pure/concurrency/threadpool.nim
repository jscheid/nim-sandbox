#
#
#            Nim's Runtime Library
#        (c) Copyright 2015 Andreas Rumpf
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.
#

## Implements Nim's 'spawn'.

when not compileOption("threads"):
  {.error: "Threadpool requires --threads:on option.".}

import cpuinfo, cpuload, locks

{.push stackTrace:off.}

type
  Semaphore = object
    c: Cond
    L: Lock
    counter: int

proc createSemaphore(): Semaphore =
  initCond(result.c)
  initLock(result.L)

proc destroySemaphore(cv: var Semaphore) {.inline.} =
  deinitCond(cv.c)
  deinitLock(cv.L)

proc await(cv: var Semaphore) =
  acquire(cv.L)
  while cv.counter <= 0:
    wait(cv.c, cv.L)
  dec cv.counter
  release(cv.L)

proc signal(cv: var Semaphore) =
  acquire(cv.L)
  inc cv.counter
  release(cv.L)
  signal(cv.c)

const CacheLineSize = 32 # true for most archs

type
  Barrier {.compilerProc.} = object
    entered: int
    cv: Semaphore # Semaphore takes 3 words at least
    when sizeof(int) < 8:
      cacheAlign: array[CacheLineSize-4*sizeof(int), byte]
    left: int
    cacheAlign2: array[CacheLineSize-sizeof(int), byte]
    interest: bool ## wether the master is interested in the "all done" event

proc barrierEnter(b: ptr Barrier) {.compilerProc, inline.} =
  # due to the signaling between threads, it is ensured we are the only
  # one with access to 'entered' so we don't need 'atomicInc' here:
  inc b.entered
  # also we need no 'fence' instructions here as soon 'nimArgsPassingDone'
  # will be called which already will perform a fence for us.

proc barrierLeave(b: ptr Barrier) {.compilerProc, inline.} =
  atomicInc b.left
  when not defined(x86): fence()
  # We may not have seen the final value of b.entered yet,
  # so we need to check for >= instead of ==.
  if b.interest and b.left >= b.entered: signal(b.cv)

proc openBarrier(b: ptr Barrier) {.compilerProc, inline.} =
  b.entered = 0
  b.left = 0
  b.interest = false

proc closeBarrier(b: ptr Barrier) {.compilerProc.} =
  fence()
  if b.left != b.entered:
    b.cv = createSemaphore()
    fence()
    b.interest = true
    fence()
    while b.left != b.entered: await(b.cv)
    destroySemaphore(b.cv)

{.pop.}

# ----------------------------------------------------------------------------

type
  foreign* = object ## a region that indicates the pointer comes from a
                    ## foreign thread heap.
  AwaitInfo = object
    cv: Semaphore
    idx: int

  FlowVarBase* = ref FlowVarBaseObj ## untyped base class for 'FlowVar[T]'
  FlowVarBaseObj = object of RootObj
    ready, usesSemaphore, awaited: bool
    cv: Semaphore #\
    # for 'awaitAny' support
    ai: ptr AwaitInfo
    idx: int
    data: pointer  # we incRef and unref it to keep it alive; note this MUST NOT
                   # be RootRef here otherwise the wrong GC keeps track of it!
    owner: pointer # ptr Worker

  FlowVarObj[T] = object of FlowVarBaseObj
    blob: T

  FlowVar*{.compilerProc.}[T] = ref FlowVarObj[T] ## a data flow variable

  ToFreeQueue = object
    len: int
    lock: Lock
    empty: Semaphore
    data: array[128, pointer]

  WorkerProc = proc (thread, args: pointer) {.nimcall, gcsafe.}
  Worker = object
    taskArrived: Semaphore
    taskStarted: Semaphore #\
    # task data:
    f: WorkerProc
    data: pointer
    ready: bool # put it here for correct alignment!
    initialized: bool # whether it has even been initialized
    shutdown: bool # the pool requests to shut down this worker thread
    q: ToFreeQueue
    readyForTask: Semaphore

proc await*(fv: FlowVarBase) =
  ## waits until the value for the flowVar arrives. Usually it is not necessary
  ## to call this explicitly.
  if fv.usesSemaphore and not fv.awaited:
    fv.awaited = true
    await(fv.cv)
    destroySemaphore(fv.cv)

proc selectWorker(w: ptr Worker; fn: WorkerProc; data: pointer): bool =
  if cas(addr w.ready, true, false):
    w.data = data
    w.f = fn
    signal(w.taskArrived)
    await(w.taskStarted)
    result = true

proc cleanFlowVars(w: ptr Worker) =
  let q = addr(w.q)
  acquire(q.lock)
  for i in 0 .. <q.len:
    GC_unref(cast[RootRef](q.data[i]))
    #echo "GC_unref"
  q.len = 0
  release(q.lock)

proc wakeupWorkerToProcessQueue(w: ptr Worker) =
  # we have to ensure it's us who wakes up the owning thread.
  # This is quite horrible code, but it runs so rarely that it doesn't matter:
  while not cas(addr w.ready, true, false):
    cpuRelax()
    discard
  w.data = nil
  w.f = proc (w, a: pointer) {.nimcall.} =
    let w = cast[ptr Worker](w)
    cleanFlowVars(w)
    signal(w.q.empty)
  signal(w.taskArrived)

proc finished(fv: FlowVarBase) =
  doAssert fv.ai.isNil, "flowVar is still attached to an 'awaitAny'"
  # we have to protect against the rare cases where the owner of the flowVar
  # simply disregards the flowVar and yet the "flowVar" has not yet written
  # anything to it:
  await(fv)
  if fv.data.isNil: return
  let owner = cast[ptr Worker](fv.owner)
  let q = addr(owner.q)
  acquire(q.lock)
  while not (q.len < q.data.len):
    #echo "EXHAUSTED!"
    release(q.lock)
    wakeupWorkerToProcessQueue(owner)
    await(q.empty)
    acquire(q.lock)
  q.data[q.len] = cast[pointer](fv.data)
  inc q.len
  release(q.lock)
  fv.data = nil

proc fvFinalizer[T](fv: FlowVar[T]) = finished(fv)

proc nimCreateFlowVar[T](): FlowVar[T] {.compilerProc.} =
  new(result, fvFinalizer)

proc nimFlowVarCreateSemaphore(fv: FlowVarBase) {.compilerProc.} =
  fv.cv = createSemaphore()
  fv.usesSemaphore = true

proc nimFlowVarSignal(fv: FlowVarBase) {.compilerProc.} =
  if fv.ai != nil:
    acquire(fv.ai.cv.L)
    fv.ai.idx = fv.idx
    inc fv.ai.cv.counter
    release(fv.ai.cv.L)
    signal(fv.ai.cv.c)
  if fv.usesSemaphore:
    signal(fv.cv)

proc awaitAndThen*[T](fv: FlowVar[T]; action: proc (x: T) {.closure.}) =
  ## blocks until the ``fv`` is available and then passes its value
  ## to ``action``. Note that due to Nim's parameter passing semantics this
  ## means that ``T`` doesn't need to be copied and so ``awaitAndThen`` can
  ## sometimes be more efficient than ``^``.
  await(fv)
  when T is string or T is seq:
    action(cast[T](fv.data))
  elif T is ref:
    {.error: "'awaitAndThen' not available for FlowVar[ref]".}
  else:
    action(fv.blob)
  finished(fv)

proc unsafeRead*[T](fv: FlowVar[ref T]): foreign ptr T =
  ## blocks until the value is available and then returns this value.
  await(fv)
  result = cast[foreign ptr T](fv.data)

proc `^`*[T](fv: FlowVar[ref T]): ref T =
  ## blocks until the value is available and then returns this value.
  await(fv)
  let src = cast[ref T](fv.data)
  deepCopy result, src

proc `^`*[T](fv: FlowVar[T]): T =
  ## blocks until the value is available and then returns this value.
  await(fv)
  when T is string or T is seq:
    # XXX closures? deepCopy?
    result = cast[T](fv.data)
  else:
    result = fv.blob

proc awaitAny*(flowVars: openArray[FlowVarBase]): int =
  ## awaits any of the given flowVars. Returns the index of one flowVar for
  ## which a value arrived. A flowVar only supports one call to 'awaitAny' at
  ## the same time. That means if you await([a,b]) and await([b,c]) the second
  ## call will only await 'c'. If there is no flowVar left to be able to wait
  ## on, -1 is returned.
  ## **Note**: This results in non-deterministic behaviour and so should be
  ## avoided.
  var ai: AwaitInfo
  ai.cv = createSemaphore()
  var conflicts = 0
  for i in 0 .. flowVars.high:
    if cas(addr flowVars[i].ai, nil, addr ai):
      flowVars[i].idx = i
    else:
      inc conflicts
  if conflicts < flowVars.len:
    await(ai.cv)
    result = ai.idx
    for i in 0 .. flowVars.high:
      discard cas(addr flowVars[i].ai, addr ai, nil)
  else:
    result = -1
  destroySemaphore(ai.cv)

proc isReady*(fv: FlowVarBase): bool =
  ## Determines whether the specified ``FlowVarBase``'s value is available.
  ##
  ## If ``true`` awaiting ``fv`` will not block.
  if fv.usesSemaphore and not fv.awaited:
    acquire(fv.cv.L)
    result = fv.cv.counter > 0
    release(fv.cv.L)
  else:
    result = true

proc nimArgsPassingDone(p: pointer) {.compilerProc.} =
  let w = cast[ptr Worker](p)
  signal(w.taskStarted)

const
  MaxThreadPoolSize* = 256 ## maximal size of the thread pool. 256 threads
                           ## should be good enough for anybody ;-)
  MaxDistinguishedThread* = 32 ## maximal number of "distinguished" threads.

type
  ThreadId* = range[0..MaxDistinguishedThread-1]

var
  currentPoolSize: int
  maxPoolSize = MaxThreadPoolSize
  minPoolSize = 4
  gSomeReady = createSemaphore()
  readyWorker: ptr Worker

proc slave(w: ptr Worker) {.thread.} =
  while true:
    when declared(atomicStoreN):
      atomicStoreN(addr(w.ready), true, ATOMIC_SEQ_CST)
    else:
      w.ready = true
    readyWorker = w
    signal(gSomeReady)
    await(w.taskArrived)
    # XXX Somebody needs to look into this (why does this assertion fail
    # in Visual Studio?)
    when not defined(vcc): assert(not w.ready)
    w.f(w, w.data)
    if w.q.len != 0: w.cleanFlowVars
    if w.shutdown:
      w.shutdown = false
      atomicDec currentPoolSize

proc distinguishedSlave(w: ptr Worker) {.thread.} =
  while true:
    when declared(atomicStoreN):
      atomicStoreN(addr(w.ready), true, ATOMIC_SEQ_CST)
    else:
      w.ready = true
    signal(w.readyForTask)
    await(w.taskArrived)
    assert(not w.ready)
    w.f(w, w.data)
    if w.q.len != 0: w.cleanFlowVars

var
  workers: array[MaxThreadPoolSize, TThread[ptr Worker]]
  workersData: array[MaxThreadPoolSize, Worker]

  distinguished: array[MaxDistinguishedThread, TThread[ptr Worker]]
  distinguishedData: array[MaxDistinguishedThread, Worker]

when defined(nimPinToCpu):
  var gCpus: Natural

proc setMinPoolSize*(size: range[1..MaxThreadPoolSize]) =
  ## sets the minimal thread pool size. The default value of this is 4.
  minPoolSize = size

proc setMaxPoolSize*(size: range[1..MaxThreadPoolSize]) =
  ## sets the maximal thread pool size. The default value of this
  ## is ``MaxThreadPoolSize``.
  maxPoolSize = size
  if currentPoolSize > maxPoolSize:
    for i in maxPoolSize..currentPoolSize-1:
      let w = addr(workersData[i])
      w.shutdown = true

when defined(nimRecursiveSpawn):
  var localThreadId {.threadvar.}: int

proc activateWorkerThread(i: int) {.noinline.} =
  workersData[i].taskArrived = createSemaphore()
  workersData[i].taskStarted = createSemaphore()
  workersData[i].initialized = true
  workersData[i].q.empty = createSemaphore()
  initLock(workersData[i].q.lock)
  createThread(workers[i], slave, addr(workersData[i]))
  when defined(nimRecursiveSpawn):
    localThreadId = i+1
  when defined(nimPinToCpu):
    if gCpus > 0: pinToCpu(workers[i], i mod gCpus)

proc activateDistinguishedThread(i: int) {.noinline.} =
  distinguishedData[i].taskArrived = createSemaphore()
  distinguishedData[i].taskStarted = createSemaphore()
  distinguishedData[i].initialized = true
  distinguishedData[i].q.empty = createSemaphore()
  initLock(distinguishedData[i].q.lock)
  distinguishedData[i].readyForTask = createSemaphore()
  createThread(distinguished[i], distinguishedSlave, addr(distinguishedData[i]))

proc setup() =
  let p = countProcessors()
  when defined(nimPinToCpu):
    gCpus = p
  currentPoolSize = min(p, MaxThreadPoolSize)
  readyWorker = addr(workersData[0])
  for i in 0.. <currentPoolSize: activateWorkerThread(i)

proc preferSpawn*(): bool =
  ## Use this proc to determine quickly if a 'spawn' or a direct call is
  ## preferable. If it returns 'true' a 'spawn' may make sense. In general
  ## it is not necessary to call this directly; use 'spawnX' instead.
  result = gSomeReady.counter > 0

proc spawn*(call: expr): expr {.magic: "Spawn".}
  ## always spawns a new task, so that the 'call' is never executed on
  ## the calling thread. 'call' has to be proc call 'p(...)' where 'p'
  ## is gcsafe and has a return type that is either 'void' or compatible
  ## with ``FlowVar[T]``.

proc pinnedSpawn*(id: ThreadId; call: expr): expr {.magic: "Spawn".}
  ## always spawns a new task on the worker thread with ``id``, so that
  ## the 'call' is **always** executed on
  ## the this thread. 'call' has to be proc call 'p(...)' where 'p'
  ## is gcsafe and has a return type that is either 'void' or compatible
  ## with ``FlowVar[T]``.

template spawnX*(call: expr): expr =
  ## spawns a new task if a CPU core is ready, otherwise executes the
  ## call in the calling thread. Usually it is advised to
  ## use 'spawn' in order to not block the producer for an unknown
  ## amount of time. 'call' has to be proc call 'p(...)' where 'p'
  ## is gcsafe and has a return type that is either 'void' or compatible
  ## with ``FlowVar[T]``.
  (if preferSpawn(): spawn call else: call)

proc parallel*(body: stmt) {.magic: "Parallel".}
  ## a parallel section can be used to execute a block in parallel. ``body``
  ## has to be in a DSL that is a particular subset of the language. Please
  ## refer to the manual for further information.

var
  state: ThreadPoolState
  stateLock: Lock

initLock stateLock

proc nimSpawn3(fn: WorkerProc; data: pointer) {.compilerProc.} =
  # implementation of 'spawn' that is used by the code generator.
  while true:
    if selectWorker(readyWorker, fn, data): return
    for i in 0.. <currentPoolSize:
      if selectWorker(addr(workersData[i]), fn, data): return
    # determine what to do, but keep in mind this is expensive too:
    # state.calls < maxPoolSize: warmup phase
    # (state.calls and 127) == 0: periodic check
    if state.calls < maxPoolSize or (state.calls and 127) == 0:
      # ensure the call to 'advice' is atomic:
      if tryAcquire(stateLock):
        case advice(state)
        of doNothing: discard
        of doCreateThread:
          if currentPoolSize < maxPoolSize:
            if not workersData[currentPoolSize].initialized:
              activateWorkerThread(currentPoolSize)
            let w = addr(workersData[currentPoolSize])
            atomicInc currentPoolSize
            if selectWorker(w, fn, data):
              release(stateLock)
              return
            # else we didn't succeed but some other thread, so do nothing.
        of doShutdownThread:
          if currentPoolSize > minPoolSize:
            let w = addr(workersData[currentPoolSize-1])
            w.shutdown = true
          # we don't free anything here. Too dangerous.
        release(stateLock)
      # else the acquire failed, but this means some
      # other thread succeeded, so we don't need to do anything here.
    when defined(nimRecursiveSpawn):
      if localThreadId > 0:
        # we are a worker thread, so instead of waiting for something which
        # might as well never happen (see tparallel_quicksort), we run the task
        # on the current thread instead.
        var self = addr(workersData[localThreadId-1])
        fn(self, data)
        await(self.taskStarted)
        return
      else:
        await(gSomeReady)
    else:
      await(gSomeReady)

var
  distinguishedLock: TLock

initLock distinguishedLock

proc nimSpawn4(fn: WorkerProc; data: pointer; id: ThreadId) {.compilerProc.} =
  acquire(distinguishedLock)
  if not distinguishedData[id].initialized:
    activateDistinguishedThread(id)
  release(distinguishedLock)
  while true:
    if selectWorker(addr(distinguishedData[id]), fn, data): break
    await(distinguishedData[id].readyForTask)


proc sync*() =
  ## a simple barrier to wait for all spawn'ed tasks. If you need more elaborate
  ## waiting, you have to use an explicit barrier.
  while true:
    var allReady = true
    for i in 0 .. <currentPoolSize:
      if not allReady: break
      allReady = allReady and workersData[i].ready
    if allReady: break
    await(gSomeReady)

setup()

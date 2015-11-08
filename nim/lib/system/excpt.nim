#
#
#            Nim's Runtime Library
#        (c) Copyright 2015 Andreas Rumpf
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.
#

# Exception handling code. Carefully coded so that tiny programs which do not
# use the heap (and nor exceptions) do not include the GC or memory allocator.

var
  errorMessageWriter*: (proc(msg: string) {.tags: [WriteIOEffect], benign.})
    ## Function that will be called
    ## instead of stdmsg.write when printing stacktrace.
    ## Unstable API.

when not defined(windows) or not defined(guiapp):
  proc writeToStdErr(msg: cstring) = write(stdmsg, msg)

else:
  proc MessageBoxA(hWnd: cint, lpText, lpCaption: cstring, uType: int): int32 {.
    header: "<windows.h>", nodecl.}

  proc writeToStdErr(msg: cstring) =
    discard MessageBoxA(0, msg, nil, 0)

proc showErrorMessage(data: cstring) =
  if errorMessageWriter != nil:
    errorMessageWriter($data)
  else:
    writeToStdErr(data)

proc chckIndx(i, a, b: int): int {.inline, compilerproc, benign.}
proc chckRange(i, a, b: int): int {.inline, compilerproc, benign.}
proc chckRangeF(x, a, b: float): float {.inline, compilerproc, benign.}
proc chckNil(p: pointer) {.noinline, compilerproc, benign.}

var
  framePtr {.threadvar.}: PFrame
  excHandler {.threadvar.}: PSafePoint
    # list of exception handlers
    # a global variable for the root of all try blocks
  currException {.threadvar.}: ref Exception

proc getFrame*(): PFrame {.compilerRtl, inl.} = framePtr

proc popFrame {.compilerRtl, inl.} =
  framePtr = framePtr.prev

proc setFrame*(s: PFrame) {.compilerRtl, inl.} =
  framePtr = s

proc pushSafePoint(s: PSafePoint) {.compilerRtl, inl.} =
  s.hasRaiseAction = false
  s.prev = excHandler
  excHandler = s

proc popSafePoint {.compilerRtl, inl.} =
  excHandler = excHandler.prev

proc pushCurrentException(e: ref Exception) {.compilerRtl, inl.} =
  e.parent = currException
  currException = e

proc popCurrentException {.compilerRtl, inl.} =
  currException = nil # currException.parent

# some platforms have native support for stack traces:
const
  nativeStackTraceSupported* = (defined(macosx) or defined(linux)) and
                              not NimStackTrace
  hasSomeStackTrace = NimStackTrace or
    defined(nativeStackTrace) and nativeStackTraceSupported

when defined(nativeStacktrace) and nativeStackTraceSupported:
  type
    TDl_info {.importc: "Dl_info", header: "<dlfcn.h>",
               final, pure.} = object
      dli_fname: cstring
      dli_fbase: pointer
      dli_sname: cstring
      dli_saddr: pointer

  proc backtrace(symbols: ptr pointer, size: int): int {.
    importc: "backtrace", header: "<execinfo.h>".}
  proc dladdr(addr1: pointer, info: ptr TDl_info): int {.
    importc: "dladdr", header: "<dlfcn.h>".}

  when not hasThreadSupport:
    var
      tempAddresses: array [0..127, pointer] # should not be alloc'd on stack
      tempDlInfo: TDl_info

  proc auxWriteStackTraceWithBacktrace(s: var string) =
    when hasThreadSupport:
      var
        tempAddresses: array [0..127, pointer] # but better than a threadvar
        tempDlInfo: TDl_info
    # This is allowed to be expensive since it only happens during crashes
    # (but this way you don't need manual stack tracing)
    var size = backtrace(cast[ptr pointer](addr(tempAddresses)),
                         len(tempAddresses))
    var enabled = false
    for i in 0..size-1:
      var dlresult = dladdr(tempAddresses[i], addr(tempDlInfo))
      if enabled:
        if dlresult != 0:
          var oldLen = s.len
          add(s, tempDlInfo.dli_fname)
          if tempDlInfo.dli_sname != nil:
            for k in 1..max(1, 25-(s.len-oldLen)): add(s, ' ')
            add(s, tempDlInfo.dli_sname)
        else:
          add(s, '?')
        add(s, "\n")
      else:
        if dlresult != 0 and tempDlInfo.dli_sname != nil and
            c_strcmp(tempDlInfo.dli_sname, "signalHandler") == 0'i32:
          # Once we're past signalHandler, we're at what the user is
          # interested in
          enabled = true

when not hasThreadSupport:
  var
    tempFrames: array [0..127, PFrame] # should not be alloc'd on stack

proc auxWriteStackTrace(f: PFrame, s: var string) =
  when hasThreadSupport:
    var
      tempFrames: array [0..127, PFrame] # but better than a threadvar
  const
    firstCalls = 32
  var
    it = f
    i = 0
    total = 0
  # setup long head:
  while it != nil and i <= high(tempFrames)-firstCalls:
    tempFrames[i] = it
    inc(i)
    inc(total)
    it = it.prev
  # go up the stack to count 'total':
  var b = it
  while it != nil:
    inc(total)
    it = it.prev
  var skipped = 0
  if total > len(tempFrames):
    # skip N
    skipped = total-i-firstCalls+1
    for j in 1..skipped:
      if b != nil: b = b.prev
    # create '...' entry:
    tempFrames[i] = nil
    inc(i)
  # setup short tail:
  while b != nil and i <= high(tempFrames):
    tempFrames[i] = b
    inc(i)
    b = b.prev
  for j in countdown(i-1, 0):
    if tempFrames[j] == nil:
      add(s, "(")
      add(s, $skipped)
      add(s, " calls omitted) ...")
    else:
      var oldLen = s.len
      add(s, tempFrames[j].filename)
      if tempFrames[j].line > 0:
        add(s, '(')
        add(s, $tempFrames[j].line)
        add(s, ')')
      for k in 1..max(1, 25-(s.len-oldLen)): add(s, ' ')
      add(s, tempFrames[j].procname)
    add(s, "\n")

proc stackTraceAvailable*(): bool

when hasSomeStackTrace:
  proc rawWriteStackTrace(s: var string) =
    when NimStackTrace:
      if framePtr == nil:
        add(s, "No stack traceback available\n")
      else:
        add(s, "Traceback (most recent call last)\n")
        auxWriteStackTrace(framePtr, s)
    elif defined(nativeStackTrace) and nativeStackTraceSupported:
      add(s, "Traceback from system (most recent call last)\n")
      auxWriteStackTraceWithBacktrace(s)
    else:
      add(s, "No stack traceback available\n")
  proc stackTraceAvailable(): bool =
    when NimStackTrace:
      if framePtr == nil:
        result = false
      else:
        result = true
    elif defined(nativeStackTrace) and nativeStackTraceSupported:
      result = true
    else:
      result = false
else:
  proc stackTraceAvailable*(): bool = result = false

proc quitOrDebug() {.inline.} =
  when not defined(endb):
    quit(1)
  else:
    endbStep() # call the debugger

proc raiseExceptionAux(e: ref Exception) =
  if localRaiseHook != nil:
    if not localRaiseHook(e): return
  if globalRaiseHook != nil:
    if not globalRaiseHook(e): return
  when defined(cpp):
    if e[] of OutOfMemError:
      showErrorMessage(e.name)
      quitOrDebug()
    else:
      pushCurrentException(e)
      {.emit: "throw NimException(`e`, `e`->name);".}
  else:
    if excHandler != nil:
      if not excHandler.hasRaiseAction or excHandler.raiseAction(e):
        pushCurrentException(e)
        c_longjmp(excHandler.context, 1)
    elif e[] of OutOfMemError:
      showErrorMessage(e.name)
      quitOrDebug()
    else:
      when hasSomeStackTrace:
        var buf = newStringOfCap(2000)
        if isNil(e.trace): rawWriteStackTrace(buf)
        else: add(buf, e.trace)
        add(buf, "Error: unhandled exception: ")
        if not isNil(e.msg): add(buf, e.msg)
        add(buf, " [")
        add(buf, $e.name)
        add(buf, "]\n")
        showErrorMessage(buf)
      else:
        # ugly, but avoids heap allocations :-)
        template xadd(buf, s, slen: expr) =
          if L + slen < high(buf):
            copyMem(addr(buf[L]), cstring(s), slen)
            inc L, slen
        template add(buf, s: expr) =
          xadd(buf, s, s.len)
        var buf: array [0..2000, char]
        var L = 0
        add(buf, "Error: unhandled exception: ")
        if not isNil(e.msg): add(buf, e.msg)
        add(buf, " [")
        xadd(buf, e.name, c_strlen(e.name))
        add(buf, "]\n")
        showErrorMessage(buf)
      quitOrDebug()

proc raiseException(e: ref Exception, ename: cstring) {.compilerRtl.} =
  e.name = ename
  when hasSomeStackTrace:
    e.trace = ""
    rawWriteStackTrace(e.trace)
  raiseExceptionAux(e)

proc reraiseException() {.compilerRtl.} =
  if currException == nil:
    sysFatal(ReraiseError, "no exception to reraise")
  else:
    raiseExceptionAux(currException)

proc writeStackTrace() =
  when hasSomeStackTrace:
    var s = ""
    rawWriteStackTrace(s)
    showErrorMessage(s)
  else:
    showErrorMessage("No stack traceback available\n")

proc getStackTrace(): string =
  when hasSomeStackTrace:
    result = ""
    rawWriteStackTrace(result)
  else:
    result = "No stack traceback available\n"

proc getStackTrace(e: ref Exception): string =
  if not isNil(e) and not isNil(e.trace):
    result = e.trace
  else:
    result = ""

when defined(nimRequiresNimFrame):
  proc stackOverflow() {.noinline.} =
    writeStackTrace()
    showErrorMessage("Stack overflow\n")
    quitOrDebug()

  proc nimFrame(s: PFrame) {.compilerRtl, inl, exportc: "nimFrame".} =
    s.calldepth = if framePtr == nil: 0 else: framePtr.calldepth+1
    s.prev = framePtr
    framePtr = s
    if s.calldepth == 2000: stackOverflow()
else:
  proc pushFrame(s: PFrame) {.compilerRtl, inl, exportc: "nimFrame".} =
    # XXX only for backwards compatibility
    s.prev = framePtr
    framePtr = s

when defined(endb):
  var
    dbgAborting: bool # whether the debugger wants to abort

when not defined(noSignalHandler):
  proc signalHandler(sig: cint) {.exportc: "signalHandler", noconv.} =
    template processSignal(s, action: expr) {.immediate,  dirty.} =
      if s == SIGINT: action("SIGINT: Interrupted by Ctrl-C.\n")
      elif s == SIGSEGV:
        action("SIGSEGV: Illegal storage access. (Attempt to read from nil?)\n")
      elif s == SIGABRT:
        when defined(endb):
          if dbgAborting: return # the debugger wants to abort
        action("SIGABRT: Abnormal termination.\n")
      elif s == SIGFPE: action("SIGFPE: Arithmetic error.\n")
      elif s == SIGILL: action("SIGILL: Illegal operation.\n")
      elif s == SIGBUS:
        action("SIGBUS: Illegal storage access. (Attempt to read from nil?)\n")
      else:
        block platformSpecificSignal:
          when declared(SIGPIPE):
            if s == SIGPIPE:
              action("SIGPIPE: Pipe closed.\n")
              break platformSpecificSignal
          action("unknown signal\n")

    # print stack trace and quit
    when hasSomeStackTrace:
      GC_disable()
      var buf = newStringOfCap(2000)
      rawWriteStackTrace(buf)
      processSignal(sig, buf.add) # nice hu? currying a la Nim :-)
      showErrorMessage(buf)
      GC_enable()
    else:
      var msg: cstring
      template asgn(y: expr) = msg = y
      processSignal(sig, asgn)
      showErrorMessage(msg)
    when defined(endb): dbgAborting = true
    quit(1) # always quit when SIGABRT

  proc registerSignalHandler() =
    c_signal(SIGINT, signalHandler)
    c_signal(SIGSEGV, signalHandler)
    c_signal(SIGABRT, signalHandler)
    c_signal(SIGFPE, signalHandler)
    c_signal(SIGILL, signalHandler)
    c_signal(SIGBUS, signalHandler)
    when declared(SIGPIPE):
      c_signal(SIGPIPE, signalHandler)

  registerSignalHandler() # call it in initialization section

proc setControlCHook(hook: proc () {.noconv.} not nil) =
  # ugly cast, but should work on all architectures:
  type SignalHandler = proc (sig: cint) {.noconv, benign.}
  {.deprecated: [TSignalHandler: SignalHandler].}
  c_signal(SIGINT, cast[SignalHandler](hook))

#
#
#            Nim's Runtime Library
#        (c) Copyright 2013 Andreas Rumpf
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.
#

# This file implements the embedded debugger that can be linked
# with the application. Mostly we do not use dynamic memory here as that
# would interfere with the GC and trigger ON/OFF errors if the
# user program corrupts memory. Unfortunately, for dispaying
# variables we use the ``system.repr()`` proc which uses Nim
# strings and thus allocates memory from the heap. Pity, but
# I do not want to implement ``repr()`` twice.

const
  EndbBeg = "*** endb"
  EndbEnd = "***\n"

type
  StaticStr = object
    len: int
    data: array[0..100, char]

  BreakpointFilename = object
    b: ptr Breakpoint
    filename: StaticStr

  DbgState = enum
    dbOff,        # debugger is turned off
    dbStepInto,   # debugger is in tracing mode
    dbStepOver,
    dbSkipCurrent,
    dbQuiting,    # debugger wants to quit
    dbBreakpoints # debugger is only interested in breakpoints
{.deprecated: [TStaticStr: StaticStr, TBreakpointFilename: BreakpointFilename,
              TDbgState: DbgState].}

var
  dbgUser: StaticStr    # buffer for user input; first command is ``step_into``
                        # needs to be global cause we store the last command
                        # in it
  dbgState: DbgState    # state of debugger
  dbgSkipToFrame: PFrame # frame to be skipped to

  maxDisplayRecDepth: int = 5 # do not display too much data!

  brkPoints: array[0..127, BreakpointFilename]

proc setLen(s: var StaticStr, newLen=0) =
  s.len = newLen
  s.data[newLen] = '\0'

proc add(s: var StaticStr, c: char) =
  if s.len < high(s.data)-1:
    s.data[s.len] = c
    s.data[s.len+1] = '\0'
    inc s.len

proc add(s: var StaticStr, c: cstring) =
  var i = 0
  while c[i] != '\0':
    add s, c[i]
    inc i

proc assign(s: var StaticStr, c: cstring) =
  setLen(s)
  add s, c

proc `==`(a, b: StaticStr): bool =
  if a.len == b.len:
    for i in 0 .. a.len-1:
      if a.data[i] != b.data[i]: return false
    return true

proc `==`(a: StaticStr, b: cstring): bool =
  result = c_strcmp(a.data, b) == 0

proc write(f: File, s: StaticStr) =
  write(f, cstring(s.data))

proc listBreakPoints() =
  write(stdout, EndbBeg)
  write(stdout, "| Breakpoints:\n")
  for b in listBreakpoints():
    write(stdout, abs(b.low))
    if b.high != b.low:
      write(stdout, "..")
      write(stdout, abs(b.high))
    write(stdout, " ")
    write(stdout, b.filename)
    if b.isActive:
      write(stdout, " [disabled]\n")
    else:
      write(stdout, "\n")
  write(stdout, EndbEnd)

proc openAppend(filename: cstring): File =
  var p: pointer = fopen(filename, "ab")
  if p != nil:
    result = cast[File](p)
    write(result, "----------------------------------------\n")

proc dbgRepr(p: pointer, typ: PNimType): string =
  var cl: ReprClosure
  initReprClosure(cl)
  cl.recDepth = maxDisplayRecDepth
  # locks for the GC turned out to be a bad idea...
  # inc(recGcLock)
  result = ""
  reprAux(result, p, typ, cl)
  # dec(recGcLock)
  deinitReprClosure(cl)

proc writeVariable(stream: File, slot: VarSlot) =
  write(stream, slot.name)
  write(stream, " = ")
  writeLine(stream, dbgRepr(slot.address, slot.typ))

proc listFrame(stream: File, f: PFrame) =
  write(stream, EndbBeg)
  write(stream, "| Frame (")
  write(stream, f.len)
  write(stream, " slots):\n")
  for i in 0 .. f.len-1:
    writeLine(stream, getLocal(f, i).name)
  write(stream, EndbEnd)

proc listLocals(stream: File, f: PFrame) =
  write(stream, EndbBeg)
  write(stream, "| Frame (")
  write(stream, f.len)
  write(stream, " slots):\n")
  for i in 0 .. f.len-1:
    writeVariable(stream, getLocal(f, i))
  write(stream, EndbEnd)

proc listGlobals(stream: File) =
  write(stream, EndbBeg)
  write(stream, "| Globals:\n")
  for i in 0 .. getGlobalLen()-1:
    writeLine(stream, getGlobal(i).name)
  write(stream, EndbEnd)

proc debugOut(msg: cstring) =
  # the *** *** markers are for easy recognition of debugger
  # output for external frontends.
  write(stdout, EndbBeg)
  write(stdout, "| ")
  write(stdout, msg)
  write(stdout, EndbEnd)

proc dbgFatal(msg: cstring) =
  debugOut(msg)
  dbgAborting = true # the debugger wants to abort
  quit(1)

proc dbgShowCurrentProc(dbgFramePointer: PFrame) =
  if dbgFramePointer != nil:
    write(stdout, "*** endb| now in proc: ")
    write(stdout, dbgFramePointer.procname)
    write(stdout, " ***\n")
  else:
    write(stdout, "*** endb| (proc name not available) ***\n")

proc dbgShowExecutionPoint() =
  write(stdout, "*** endb| ")
  write(stdout, framePtr.filename)
  write(stdout, "(")
  write(stdout, framePtr.line)
  write(stdout, ") ")
  write(stdout, framePtr.procname)
  write(stdout, " ***\n")

proc scanAndAppendWord(src: cstring, a: var StaticStr, start: int): int =
  result = start
  # skip whitespace:
  while src[result] in {'\t', ' '}: inc(result)
  while true:
    case src[result]
    of 'a'..'z', '0'..'9': add(a, src[result])
    of '_': discard # just skip it
    of 'A'..'Z': add(a, chr(ord(src[result]) - ord('A') + ord('a')))
    else: break
    inc(result)

proc scanWord(src: cstring, a: var StaticStr, start: int): int =
  setlen(a)
  result = scanAndAppendWord(src, a, start)

proc scanFilename(src: cstring, a: var StaticStr, start: int): int =
  result = start
  setLen a
  while src[result] in {'\t', ' '}: inc(result)
  while src[result] notin {'\t', ' ', '\0'}:
    add(a, src[result])
    inc(result)

proc scanNumber(src: cstring, a: var int, start: int): int =
  result = start
  a = 0
  while src[result] in {'\t', ' '}: inc(result)
  while true:
    case src[result]
    of '0'..'9': a = a * 10 + ord(src[result]) - ord('0')
    of '_': discard # skip underscores (nice for long line numbers)
    else: break
    inc(result)

proc dbgHelp() =
  debugOut("""
list of commands (see the manual for further help):
              GENERAL
h, help                 display this help message
q, quit                 quit the debugger and the program
<ENTER>                 repeat the previous debugger command
              EXECUTING
s, step                 single step, stepping into routine calls
n, next                 single step, without stepping into routine calls
f, skipcurrent          continue execution until the current routine finishes
c, continue, r, run     continue execution until the next breakpoint
i, ignore               continue execution, ignore all breakpoints
              BREAKPOINTS
b, break [fromline [toline]] [file]
                        set a new breakpoint for line and file
                        if line or file are omitted the current one is used
breakpoints             display the entire breakpoint list
toggle fromline [file]  enable or disable a breakpoint
filenames               list all valid filenames
              DATA DISPLAY
e, eval <expr>          evaluate the expression <expr>
o, out <file> <expr>    evaluate <expr> and write it to <file>
w, where                display the current execution point
stackframe [file]       display current stack frame [and write it to file]
u, up                   go up in the call stack
d, down                 go down in the call stack
bt, backtrace           display the entire call stack
l, locals               display available local variables
g, globals              display available global variables
maxdisplay <integer>    set the display's recursion maximum
""")

proc invalidCommand() =
  debugOut("[Warning] invalid command ignored (type 'h' for help) ")

proc hasExt(s: cstring): bool =
  # returns true if s has a filename extension
  var i = 0
  while s[i] != '\0':
    if s[i] == '.': return true
    inc i

proc parseBreakpoint(s: cstring, start: int): Breakpoint =
  var dbgTemp: StaticStr
  var i = scanNumber(s, result.low, start)
  if result.low == 0: result.low = framePtr.line
  i = scanNumber(s, result.high, i)
  if result.high == 0: result.high = result.low
  i = scanFilename(s, dbgTemp, i)
  if dbgTemp.len != 0:
    if not hasExt(dbgTemp.data): add(dbgTemp, ".nim")
    result.filename = canonFilename(dbgTemp.data.cstring)
    if result.filename.isNil:
      debugOut("[Warning] no breakpoint could be set; unknown filename ")
      return
  else:
    result.filename = framePtr.filename

proc createBreakPoint(s: cstring, start: int) =
  let br = parseBreakpoint(s, start)
  if not br.filename.isNil:
    if not addBreakpoint(br.filename, br.low, br.high):
      debugOut("[Warning] no breakpoint could be set; out of breakpoint space ")

proc breakpointToggle(s: cstring, start: int) =
  var a = parseBreakpoint(s, start)
  if not a.filename.isNil:
    var b = checkBreakpoints(a.filename, a.low)
    if not b.isNil: b.flip
    else: debugOut("[Warning] unknown breakpoint ")

proc dbgEvaluate(stream: File, s: cstring, start: int, f: PFrame) =
  var dbgTemp: StaticStr
  var i = scanWord(s, dbgTemp, start)
  while s[i] in {' ', '\t'}: inc(i)
  var v: VarSlot
  if s[i] == '.':
    inc(i)
    add(dbgTemp, '.')
    i = scanAndAppendWord(s, dbgTemp, i)
    for i in 0 .. getGlobalLen()-1:
      let v = getGlobal(i)
      if c_strcmp(v.name, dbgTemp.data) == 0:
        writeVariable(stream, v)
  else:
    for i in 0 .. f.len-1:
      let v = getLocal(f, i)
      if c_strcmp(v.name, dbgTemp.data) == 0:
        writeVariable(stream, v)

proc dbgOut(s: cstring, start: int, currFrame: PFrame) =
  var dbgTemp: StaticStr
  var i = scanFilename(s, dbgTemp, start)
  if dbgTemp.len == 0:
    invalidCommand()
    return
  var stream = openAppend(dbgTemp.data)
  if stream == nil:
    debugOut("[Warning] could not open or create file ")
    return
  dbgEvaluate(stream, s, i, currFrame)
  close(stream)

proc dbgStackFrame(s: cstring, start: int, currFrame: PFrame) =
  var dbgTemp: StaticStr
  var i = scanFilename(s, dbgTemp, start)
  if dbgTemp.len == 0:
    # just write it to stdout:
    listFrame(stdout, currFrame)
  else:
    var stream = openAppend(dbgTemp.data)
    if stream == nil:
      debugOut("[Warning] could not open or create file ")
      return
    listFrame(stream, currFrame)
    close(stream)

proc readLine(f: File, line: var StaticStr): bool =
  while true:
    var c = fgetc(f)
    if c < 0'i32:
      if line.len > 0: break
      else: return false
    if c == 10'i32: break # LF
    if c == 13'i32:  # CR
      c = fgetc(f) # is the next char LF?
      if c != 10'i32: ungetc(c, f) # no, put the character back
      break
    add line, chr(int(c))
  result = true

proc listFilenames() =
  write(stdout, EndbBeg)
  write(stdout, "| Files:\n")
  var i = 0
  while true:
    let x = dbgFilenames[i]
    if x.isNil: break
    write(stdout, x)
    write(stdout, "\n")
    inc i
  write(stdout, EndbEnd)

proc dbgWriteStackTrace(f: PFrame)
proc commandPrompt() =
  # if we return from this routine, user code executes again
  var
    again = true
    dbgFramePtr = framePtr # for going down and up the stack
    dbgDown = 0 # how often we did go down
    dbgTemp: StaticStr

  while again:
    write(stdout, "*** endb| >>")
    let oldLen = dbgUser.len
    dbgUser.len = 0
    if not readLine(stdin, dbgUser): break
    if dbgUser.len == 0: dbgUser.len = oldLen
    # now look what we have to do:
    var i = scanWord(dbgUser.data, dbgTemp, 0)
    template `?`(x: expr): expr = dbgTemp == cstring(x)
    if ?"s" or ?"step":
      dbgState = dbStepInto
      again = false
    elif ?"n" or ?"next":
      dbgState = dbStepOver
      dbgSkipToFrame = framePtr
      again = false
    elif ?"f" or ?"skipcurrent":
      dbgState = dbSkipCurrent
      dbgSkipToFrame = framePtr.prev
      again = false
    elif ?"c" or ?"continue" or ?"r" or ?"run":
      dbgState = dbBreakpoints
      again = false
    elif ?"i" or ?"ignore":
      dbgState = dbOff
      again = false
    elif ?"h" or ?"help":
      dbgHelp()
    elif ?"q" or ?"quit":
      dbgState = dbQuiting
      dbgAborting = true
      again = false
      quit(1) # BUGFIX: quit with error code > 0
    elif ?"e" or ?"eval":
      var
        prevState = dbgState
        prevSkipFrame = dbgSkipToFrame
      dbgState = dbSkipCurrent
      dbgEvaluate(stdout, dbgUser.data, i, dbgFramePtr)
      dbgState = prevState
      dbgSkipToFrame = prevSkipFrame
    elif ?"o" or ?"out":
      dbgOut(dbgUser.data, i, dbgFramePtr)
    elif ?"stackframe":
      dbgStackFrame(dbgUser.data, i, dbgFramePtr)
    elif ?"w" or ?"where":
      dbgShowExecutionPoint()
    elif ?"l" or ?"locals":
      var
        prevState = dbgState
        prevSkipFrame = dbgSkipToFrame
      dbgState = dbSkipCurrent
      listLocals(stdout, dbgFramePtr)
      dbgState = prevState
      dbgSkipToFrame = prevSkipFrame
    elif ?"g" or ?"globals":
      var
        prevState = dbgState
        prevSkipFrame = dbgSkipToFrame
      dbgState = dbSkipCurrent
      listGlobals(stdout)
      dbgState = prevState
      dbgSkipToFrame = prevSkipFrame
    elif ?"u" or ?"up":
      if dbgDown <= 0:
        debugOut("[Warning] cannot go up any further ")
      else:
        dbgFramePtr = framePtr
        for j in 0 .. dbgDown-2: # BUGFIX
          dbgFramePtr = dbgFramePtr.prev
        dec(dbgDown)
      dbgShowCurrentProc(dbgFramePtr)
    elif ?"d" or ?"down":
      if dbgFramePtr != nil:
        inc(dbgDown)
        dbgFramePtr = dbgFramePtr.prev
        dbgShowCurrentProc(dbgFramePtr)
      else:
        debugOut("[Warning] cannot go down any further ")
    elif ?"bt" or ?"backtrace":
      dbgWriteStackTrace(framePtr)
    elif ?"b" or ?"break":
      createBreakPoint(dbgUser.data, i)
    elif ?"breakpoints":
      listBreakPoints()
    elif ?"toggle":
      breakpointToggle(dbgUser.data, i)
    elif ?"filenames":
      listFilenames()
    elif ?"maxdisplay":
      var parsed: int
      i = scanNumber(dbgUser.data, parsed, i)
      if dbgUser.data[i-1] in {'0'..'9'}:
        if parsed == 0: maxDisplayRecDepth = -1
        else: maxDisplayRecDepth = parsed
      else:
        invalidCommand()
    else: invalidCommand()

proc endbStep() =
  # we get into here if an unhandled exception has been raised
  # XXX: do not allow the user to run the program any further?
  # XXX: BUG: the frame is lost here!
  dbgShowExecutionPoint()
  commandPrompt()

proc dbgWriteStackTrace(f: PFrame) =
  const
    firstCalls = 32
  var
    it = f
    i = 0
    total = 0
    tempFrames: array [0..127, PFrame]
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
      write(stdout, "(")
      write(stdout, skipped)
      write(stdout, " calls omitted) ...")
    else:
      write(stdout, tempFrames[j].filename)
      if tempFrames[j].line > 0:
        write(stdout, '(')
        write(stdout, tempFrames[j].line)
        write(stdout, ')')
      write(stdout, ' ')
      write(stdout, tempFrames[j].procname)
    write(stdout, "\n")

proc checkForBreakpoint =
  let b = checkBreakpoints(framePtr.filename, framePtr.line)
  if b != nil:
    write(stdout, "*** endb| reached ")
    write(stdout, framePtr.filename)
    write(stdout, "(")
    write(stdout, framePtr.line)
    write(stdout, ") ")
    write(stdout, framePtr.procname)
    write(stdout, " ***\n")
    commandPrompt()

proc lineHookImpl() {.nimcall.} =
  case dbgState
  of dbStepInto:
    # we really want the command prompt here:
    dbgShowExecutionPoint()
    commandPrompt()
  of dbSkipCurrent, dbStepOver: # skip current routine
    if framePtr == dbgSkipToFrame:
      dbgShowExecutionPoint()
      commandPrompt()
    else:
      # breakpoints are wanted though (I guess)
      checkForBreakpoint()
  of dbBreakpoints:
    # debugger is only interested in breakpoints
    checkForBreakpoint()
  else: discard

proc watchpointHookImpl(name: cstring) {.nimcall.} =
  dbgWriteStackTrace(framePtr)
  debugOut(name)

proc initDebugger {.inline.} =
  dbgState = dbStepInto
  dbgUser.len = 1
  dbgUser.data[0] = 's'
  dbgWatchpointHook = watchpointHookImpl
  dbgLineHook = lineHookImpl

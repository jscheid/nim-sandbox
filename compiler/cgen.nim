#
#
#           The Nim Compiler
#        (c) Copyright 2015 Andreas Rumpf
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.
#

## This module implements the C code generator.

import
  ast, astalgo, hashes, trees, platform, magicsys, extccomp, options, intsets,
  nversion, nimsets, msgs, securehash, bitsets, idents, lists, types,
  ccgutils, os, ropes, math, passes, rodread, wordrecg, treetab, cgmeth,
  condsyms, rodutils, renderer, idgen, cgendata, ccgmerge, semfold, aliases,
  lowerings, semparallel

import strutils except `%` # collides with ropes.`%`

when options.hasTinyCBackend:
  import tccgen

# implementation

var
  generatedHeader: BModule

proc addForwardedProc(m: BModule, prc: PSym) =
  m.forwardedProcs.add(prc)
  inc(gForwardedProcsCounter)

proc getCgenModule(s: PSym): BModule =
  result = if s.position >= 0 and s.position < gModules.len: gModules[s.position]
           else: nil

proc findPendingModule(m: BModule, s: PSym): BModule =
  var ms = getModule(s)
  result = gModules[ms.position]

proc emitLazily(s: PSym): bool {.inline.} =
  result = optDeadCodeElim in gGlobalOptions or
           sfDeadCodeElim in getModule(s).flags

proc initLoc(result: var TLoc, k: TLocKind, typ: PType, s: TStorageLoc) =
  result.k = k
  result.s = s
  result.t = typ
  result.r = nil
  result.flags = {}

proc fillLoc(a: var TLoc, k: TLocKind, typ: PType, r: Rope, s: TStorageLoc) =
  # fills the loc if it is not already initialized
  if a.k == locNone:
    a.k = k
    a.t = typ
    a.s = s
    if a.r == nil: a.r = r

proc isSimpleConst(typ: PType): bool =
  let t = skipTypes(typ, abstractVar)
  result = t.kind notin
      {tyTuple, tyObject, tyArray, tyArrayConstr, tySet, tySequence} and not
      (t.kind == tyProc and t.callConv == ccClosure)

proc useStringh(m: BModule) =
  if not m.includesStringh:
    m.includesStringh = true
    discard lists.includeStr(m.headerFiles, "<string.h>")

proc useHeader(m: BModule, sym: PSym) =
  if lfHeader in sym.loc.flags:
    assert(sym.annex != nil)
    discard lists.includeStr(m.headerFiles, getStr(sym.annex.path))

proc cgsym(m: BModule, name: string): Rope

proc ropecg(m: BModule, frmt: FormatStr, args: varargs[Rope]): Rope =
  var i = 0
  var length = len(frmt)
  result = nil
  var num = 0
  while i < length:
    if frmt[i] == '$':
      inc(i)                  # skip '$'
      case frmt[i]
      of '$':
        add(result, "$")
        inc(i)
      of '#':
        inc(i)
        add(result, args[num])
        inc(num)
      of '0'..'9':
        var j = 0
        while true:
          j = (j * 10) + ord(frmt[i]) - ord('0')
          inc(i)
          if i >= length or not (frmt[i] in {'0'..'9'}): break
        num = j
        if j > high(args) + 1:
          internalError("ropes: invalid format string $" & $j)
        add(result, args[j-1])
      of 'n':
        if optLineDir notin gOptions: add(result, rnl)
        inc(i)
      of 'N':
        add(result, rnl)
        inc(i)
      else: internalError("ropes: invalid format string $" & frmt[i])
    elif frmt[i] == '#' and frmt[i+1] in IdentStartChars:
      inc(i)
      var j = i
      while frmt[j] in IdentChars: inc(j)
      var ident = substr(frmt, i, j-1)
      i = j
      add(result, cgsym(m, ident))
    elif frmt[i] == '#' and frmt[i+1] == '$':
      inc(i, 2)
      var j = 0
      while frmt[i] in Digits:
        j = (j * 10) + ord(frmt[i]) - ord('0')
        inc(i)
      add(result, cgsym(m, $args[j-1]))
    var start = i
    while i < length:
      if frmt[i] != '$' and frmt[i] != '#': inc(i)
      else: break
    if i - 1 >= start:
      add(result, substr(frmt, start, i - 1))

template rfmt(m: BModule, fmt: string, args: varargs[Rope]): expr =
  ropecg(m, fmt, args)

proc appcg(m: BModule, c: var Rope, frmt: FormatStr,
           args: varargs[Rope]) =
  add(c, ropecg(m, frmt, args))

proc appcg(m: BModule, s: TCFileSection, frmt: FormatStr,
           args: varargs[Rope]) =
  add(m.s[s], ropecg(m, frmt, args))

proc appcg(p: BProc, s: TCProcSection, frmt: FormatStr,
           args: varargs[Rope]) =
  add(p.s(s), ropecg(p.module, frmt, args))

var indent = "\t".rope
proc indentLine(p: BProc, r: Rope): Rope =
  result = r
  for i in countup(0, p.blocks.len-1): prepend(result, indent)

proc line(p: BProc, s: TCProcSection, r: Rope) =
  add(p.s(s), indentLine(p, r))

proc line(p: BProc, s: TCProcSection, r: string) =
  add(p.s(s), indentLine(p, r.rope))

proc lineF(p: BProc, s: TCProcSection, frmt: FormatStr,
              args: openarray[Rope]) =
  add(p.s(s), indentLine(p, frmt % args))

proc lineCg(p: BProc, s: TCProcSection, frmt: FormatStr,
               args: varargs[Rope]) =
  add(p.s(s), indentLine(p, ropecg(p.module, frmt, args)))

proc linefmt(p: BProc, s: TCProcSection, frmt: FormatStr,
             args: varargs[Rope]) =
  add(p.s(s), indentLine(p, ropecg(p.module, frmt, args)))

proc appLineCg(p: BProc, r: var Rope, frmt: FormatStr,
               args: varargs[Rope]) =
  add(r, indentLine(p, ropecg(p.module, frmt, args)))

proc safeLineNm(info: TLineInfo): int =
  result = toLinenumber(info)
  if result < 0: result = 0 # negative numbers are not allowed in #line

proc genCLineDir(r: var Rope, filename: string, line: int) =
  assert line >= 0
  if optLineDir in gOptions:
    addf(r, "$N#line $2 $1$N",
        [rope(makeSingleLineCString(filename)), rope(line)])

proc genCLineDir(r: var Rope, info: TLineInfo) =
  genCLineDir(r, info.toFullPath, info.safeLineNm)

proc freshLineInfo(p: BProc; info: TLineInfo): bool =
  if p.lastLineInfo.line != info.line or
     p.lastLineInfo.fileIndex != info.fileIndex:
    p.lastLineInfo.line = info.line
    p.lastLineInfo.fileIndex = info.fileIndex
    result = true

proc genLineDir(p: BProc, t: PNode) =
  var line = t.info.safeLineNm
  if optEmbedOrigSrc in gGlobalOptions:
    add(p.s(cpsStmts), ~"//" & t.info.sourceLine & rnl)
  genCLineDir(p.s(cpsStmts), t.info.toFullPath, line)
  if ({optStackTrace, optEndb} * p.options == {optStackTrace, optEndb}) and
      (p.prc == nil or sfPure notin p.prc.flags):
    if freshLineInfo(p, t.info):
      linefmt(p, cpsStmts, "#endb($1, $2);$n",
              line.rope, makeCString(toFilename(t.info)))
  elif ({optLineTrace, optStackTrace} * p.options ==
      {optLineTrace, optStackTrace}) and
      (p.prc == nil or sfPure notin p.prc.flags) and t.info.fileIndex >= 0:
    if freshLineInfo(p, t.info):
      linefmt(p, cpsStmts, "nimln($1, $2);$n",
              line.rope, t.info.quotedFilename)

proc postStmtActions(p: BProc) {.inline.} =
  add(p.s(cpsStmts), p.module.injectStmt)

proc accessThreadLocalVar(p: BProc, s: PSym)
proc emulatedThreadVars(): bool {.inline.}
proc genProc(m: BModule, prc: PSym)

template compileToCpp(m: BModule): expr =
  gCmd == cmdCompileToCpp or sfCompileToCpp in m.module.flags

include "ccgtypes.nim"

# ------------------------------ Manager of temporaries ------------------

proc rdLoc(a: TLoc): Rope =
  # 'read' location (deref if indirect)
  result = a.r
  if lfIndirect in a.flags: result = "(*$1)" % [result]

proc addrLoc(a: TLoc): Rope =
  result = a.r
  if lfIndirect notin a.flags and mapType(a.t) != ctArray:
    result = "(&" & result & ")"

proc rdCharLoc(a: TLoc): Rope =
  # read a location that may need a char-cast:
  result = rdLoc(a)
  if skipTypes(a.t, abstractRange).kind == tyChar:
    result = "((NU8)($1))" % [result]

proc genObjectInit(p: BProc, section: TCProcSection, t: PType, a: TLoc,
                   takeAddr: bool) =
  case analyseObjectWithTypeField(t)
  of frNone:
    discard
  of frHeader:
    var r = rdLoc(a)
    if not takeAddr: r = "(*$1)" % [r]
    var s = skipTypes(t, abstractInst)
    if not p.module.compileToCpp:
      while (s.kind == tyObject) and (s.sons[0] != nil):
        add(r, ".Sup")
        s = skipTypes(s.sons[0], abstractInst)
    linefmt(p, section, "$1.m_type = $2;$n", r, genTypeInfo(p.module, t))
  of frEmbedded:
    # worst case for performance:
    var r = if takeAddr: addrLoc(a) else: rdLoc(a)
    linefmt(p, section, "#objectInit($1, $2);$n", r, genTypeInfo(p.module, t))

type
  TAssignmentFlag = enum
    needToCopy, needForSubtypeCheck, afDestIsNil, afDestIsNotNil, afSrcIsNil,
    afSrcIsNotNil, needToKeepAlive
  TAssignmentFlags = set[TAssignmentFlag]

proc genRefAssign(p: BProc, dest, src: TLoc, flags: TAssignmentFlags)

proc isComplexValueType(t: PType): bool {.inline.} =
  result = t.kind in {tyArray, tyArrayConstr, tySet, tyTuple, tyObject} or
    (t.kind == tyProc and t.callConv == ccClosure)

proc resetLoc(p: BProc, loc: var TLoc) =
  let containsGcRef = containsGarbageCollectedRef(loc.t)
  let typ = skipTypes(loc.t, abstractVarRange)
  if isImportedCppType(typ): return
  if not isComplexValueType(typ):
    if containsGcRef:
      var nilLoc: TLoc
      initLoc(nilLoc, locTemp, loc.t, OnStack)
      nilLoc.r = rope("NIM_NIL")
      genRefAssign(p, loc, nilLoc, {afSrcIsNil})
    else:
      linefmt(p, cpsStmts, "$1 = 0;$n", rdLoc(loc))
  else:
    if optNilCheck in p.options:
      linefmt(p, cpsStmts, "#chckNil((void*)$1);$n", addrLoc(loc))
    if loc.s != OnStack:
      linefmt(p, cpsStmts, "#genericReset((void*)$1, $2);$n",
              addrLoc(loc), genTypeInfo(p.module, loc.t))
      # XXX: generated reset procs should not touch the m_type
      # field, so disabling this should be safe:
      genObjectInit(p, cpsStmts, loc.t, loc, true)
    else:
      useStringh(p.module)
      linefmt(p, cpsStmts, "memset((void*)$1, 0, sizeof($2));$n",
              addrLoc(loc), rdLoc(loc))
      # XXX: We can be extra clever here and call memset only
      # on the bytes following the m_type field?
      genObjectInit(p, cpsStmts, loc.t, loc, true)

proc constructLoc(p: BProc, loc: TLoc, isTemp = false) =
  let typ = skipTypes(loc.t, abstractRange)
  if not isComplexValueType(typ):
    linefmt(p, cpsStmts, "$1 = 0;$n", rdLoc(loc))
  else:
    if not isTemp or containsGarbageCollectedRef(loc.t):
      # don't use memset for temporary values for performance if we can
      # avoid it:
      if not isImportedCppType(typ):
        useStringh(p.module)
        linefmt(p, cpsStmts, "memset((void*)$1, 0, sizeof($2));$n",
                addrLoc(loc), rdLoc(loc))
    genObjectInit(p, cpsStmts, loc.t, loc, true)

proc initLocalVar(p: BProc, v: PSym, immediateAsgn: bool) =
  if sfNoInit notin v.flags:
    # we know it is a local variable and thus on the stack!
    # If ``not immediateAsgn`` it is not initialized in a binding like
    # ``var v = X`` and thus we need to init it.
    # If ``v`` contains a GC-ref we may pass it to ``unsureAsgnRef`` somehow
    # which requires initialization. However this can really only happen if
    # ``var v = X()`` gets transformed into ``X(&v)``.
    # Nowadays the logic in ccgcalls deals with this case however.
    if not immediateAsgn:
      constructLoc(p, v.loc)

proc getTemp(p: BProc, t: PType, result: var TLoc; needsInit=false) =
  inc(p.labels)
  result.r = "LOC" & rope(p.labels)
  linefmt(p, cpsLocals, "$1 $2;$n", getTypeDesc(p.module, t), result.r)
  result.k = locTemp
  #result.a = - 1
  result.t = getUniqueType(t)
  result.s = OnStack
  result.flags = {}
  constructLoc(p, result, not needsInit)

proc keepAlive(p: BProc, toKeepAlive: TLoc) =
  when false:
    # deactivated because of the huge slowdown this causes; GC will take care
    # of interior pointers instead
    if optRefcGC notin gGlobalOptions: return
    var result: TLoc
    var fid = rope(p.gcFrameId)
    result.r = "GCFRAME.F" & fid
    addf(p.gcFrameType, "  $1 F$2;$n",
        [getTypeDesc(p.module, toKeepAlive.t), fid])
    inc(p.gcFrameId)
    result.k = locTemp
    #result.a = -1
    result.t = toKeepAlive.t
    result.s = OnStack
    result.flags = {}

    if not isComplexValueType(skipTypes(toKeepAlive.t, abstractVarRange)):
      linefmt(p, cpsStmts, "$1 = $2;$n", rdLoc(result), rdLoc(toKeepAlive))
    else:
      useStringh(p.module)
      linefmt(p, cpsStmts,
           "memcpy((void*)$1, (NIM_CONST void*)$2, sizeof($3));$n",
           addrLoc(result), addrLoc(toKeepAlive), rdLoc(result))

proc initGCFrame(p: BProc): Rope =
  if p.gcFrameId > 0: result = "struct {$1} GCFRAME;$n" % [p.gcFrameType]

proc deinitGCFrame(p: BProc): Rope =
  if p.gcFrameId > 0:
    result = ropecg(p.module,
                    "if (((NU)&GCFRAME) < 4096) #nimGCFrame(&GCFRAME);$n")

proc localDebugInfo(p: BProc, s: PSym) =
  if {optStackTrace, optEndb} * p.options != {optStackTrace, optEndb}: return
  # XXX work around a bug: No type information for open arrays possible:
  if skipTypes(s.typ, abstractVar).kind in {tyOpenArray, tyVarargs}: return
  var a = "&" & s.loc.r
  if s.kind == skParam and ccgIntroducedPtr(s): a = s.loc.r
  lineF(p, cpsInit,
       "FR.s[$1].address = (void*)$3; FR.s[$1].typ = $4; FR.s[$1].name = $2;$n",
       [p.maxFrameLen.rope, makeCString(normalize(s.name.s)), a,
        genTypeInfo(p.module, s.loc.t)])
  inc(p.maxFrameLen)
  inc p.blocks[p.blocks.len-1].frameLen

proc localVarDecl(p: BProc; s: PSym): Rope =
  if s.loc.k == locNone:
    fillLoc(s.loc, locLocalVar, s.typ, mangleName(s), OnStack)
    if s.kind == skLet: incl(s.loc.flags, lfNoDeepCopy)
  result = getTypeDesc(p.module, s.loc.t)
  if s.constraint.isNil:
    if sfRegister in s.flags: add(result, " register")
    #elif skipTypes(s.typ, abstractInst).kind in GcTypeKinds:
    #  add(decl, " GC_GUARD")
    if sfVolatile in s.flags: add(result, " volatile")
    add(result, " ")
    add(result, s.loc.r)
  else:
    result = s.cgDeclFrmt % [result, s.loc.r]

proc assignLocalVar(p: BProc, s: PSym) =
  #assert(s.loc.k == locNone) # not yet assigned
  # this need not be fulfilled for inline procs; they are regenerated
  # for each module that uses them!
  let decl = localVarDecl(p, s) & ";" & tnl
  line(p, cpsLocals, decl)
  localDebugInfo(p, s)

include ccgthreadvars

proc varInDynamicLib(m: BModule, sym: PSym)
proc mangleDynLibProc(sym: PSym): Rope

proc assignGlobalVar(p: BProc, s: PSym) =
  if s.loc.k == locNone:
    fillLoc(s.loc, locGlobalVar, s.typ, mangleName(s), OnHeap)

  if lfDynamicLib in s.loc.flags:
    var q = findPendingModule(p.module, s)
    if q != nil and not containsOrIncl(q.declaredThings, s.id):
      varInDynamicLib(q, s)
    else:
      s.loc.r = mangleDynLibProc(s)
    return
  useHeader(p.module, s)
  if lfNoDecl in s.loc.flags: return
  if sfThread in s.flags:
    declareThreadVar(p.module, s, sfImportc in s.flags)
  else:
    var decl: Rope = nil
    var td = getTypeDesc(p.module, s.loc.t)
    if s.constraint.isNil:
      if sfImportc in s.flags: add(decl, "extern ")
      add(decl, td)
      if sfRegister in s.flags: add(decl, " register")
      if sfVolatile in s.flags: add(decl, " volatile")
      addf(decl, " $1;$n", [s.loc.r])
    else:
      decl = (s.cgDeclFrmt & ";$n") % [td, s.loc.r]
    add(p.module.s[cfsVars], decl)
  if p.withinLoop > 0:
    # fixes tests/run/tzeroarray:
    resetLoc(p, s.loc)
  if p.module.module.options * {optStackTrace, optEndb} ==
                               {optStackTrace, optEndb}:
    appcg(p.module, p.module.s[cfsDebugInit],
          "#dbgRegisterGlobal($1, &$2, $3);$n",
         [makeCString(normalize(s.owner.name.s & '.' & s.name.s)),
          s.loc.r, genTypeInfo(p.module, s.typ)])

proc assignParam(p: BProc, s: PSym) =
  assert(s.loc.r != nil)
  localDebugInfo(p, s)

proc fillProcLoc(sym: PSym) =
  if sym.loc.k == locNone:
    fillLoc(sym.loc, locProc, sym.typ, mangleName(sym), OnStack)

proc getLabel(p: BProc): TLabel =
  inc(p.labels)
  result = "LA" & rope(p.labels)

proc fixLabel(p: BProc, labl: TLabel) =
  lineF(p, cpsStmts, "$1: ;$n", [labl])

proc genVarPrototype(m: BModule, sym: PSym)
proc requestConstImpl(p: BProc, sym: PSym)
proc genStmts(p: BProc, t: PNode)
proc expr(p: BProc, n: PNode, d: var TLoc)
proc genProcPrototype(m: BModule, sym: PSym)
proc putLocIntoDest(p: BProc, d: var TLoc, s: TLoc)
proc genAssignment(p: BProc, dest, src: TLoc, flags: TAssignmentFlags)
proc intLiteral(i: BiggestInt): Rope
proc genLiteral(p: BProc, n: PNode): Rope
proc genOtherArg(p: BProc; ri: PNode; i: int; typ: PType): Rope

proc initLocExpr(p: BProc, e: PNode, result: var TLoc) =
  initLoc(result, locNone, e.typ, OnUnknown)
  expr(p, e, result)

proc initLocExprSingleUse(p: BProc, e: PNode, result: var TLoc) =
  initLoc(result, locNone, e.typ, OnUnknown)
  result.flags.incl lfSingleUse
  expr(p, e, result)

proc lenField(p: BProc): Rope =
  result = rope(if p.module.compileToCpp: "len" else: "Sup.len")

include ccgcalls, "ccgstmts.nim", "ccgexprs.nim"

# ----------------------------- dynamic library handling -----------------
# We don't finalize dynamic libs as the OS does this for us.

proc isGetProcAddr(lib: PLib): bool =
  let n = lib.path
  result = n.kind in nkCallKinds and n.typ != nil and
    n.typ.kind in {tyPointer, tyProc}

proc loadDynamicLib(m: BModule, lib: PLib) =
  assert(lib != nil)
  if not lib.generated:
    lib.generated = true
    var tmp = getGlobalTempName()
    assert(lib.name == nil)
    lib.name = tmp # BUGFIX: cgsym has awful side-effects
    addf(m.s[cfsVars], "static void* $1;$n", [tmp])
    if lib.path.kind in {nkStrLit..nkTripleStrLit}:
      var s: TStringSeq = @[]
      libCandidates(lib.path.strVal, s)
      rawMessage(hintDependency, lib.path.strVal)
      var loadlib: Rope = nil
      for i in countup(0, high(s)):
        inc(m.labels)
        if i > 0: add(loadlib, "||")
        appcg(m, loadlib, "($1 = #nimLoadLibrary((#NimStringDesc*) &$2))$n",
              [tmp, getStrLit(m, s[i])])
      appcg(m, m.s[cfsDynLibInit],
            "if (!($1)) #nimLoadLibraryError((#NimStringDesc*) &$2);$n",
            [loadlib, getStrLit(m, lib.path.strVal)])
    else:
      var p = newProc(nil, m)
      p.options = p.options - {optStackTrace, optEndb}
      var dest: TLoc
      initLocExpr(p, lib.path, dest)
      add(m.s[cfsVars], p.s(cpsLocals))
      add(m.s[cfsDynLibInit], p.s(cpsInit))
      add(m.s[cfsDynLibInit], p.s(cpsStmts))
      appcg(m, m.s[cfsDynLibInit],
           "if (!($1 = #nimLoadLibrary($2))) #nimLoadLibraryError($2);$n",
           [tmp, rdLoc(dest)])

  if lib.name == nil: internalError("loadDynamicLib")

proc mangleDynLibProc(sym: PSym): Rope =
  if sfCompilerProc in sym.flags:
    # NOTE: sym.loc.r is the external name!
    result = rope(sym.name.s)
  else:
    result = "Dl_$1" % [rope(sym.id)]

proc symInDynamicLib(m: BModule, sym: PSym) =
  var lib = sym.annex
  let isCall = isGetProcAddr(lib)
  var extname = sym.loc.r
  if not isCall: loadDynamicLib(m, lib)
  var tmp = mangleDynLibProc(sym)
  sym.loc.r = tmp             # from now on we only need the internal name
  sym.typ.sym = nil           # generate a new name
  inc(m.labels, 2)
  if isCall:
    let n = lib.path
    var a: TLoc
    initLocExpr(m.initProc, n[0], a)
    var params = rdLoc(a) & "("
    for i in 1 .. n.len-2:
      initLocExpr(m.initProc, n[i], a)
      params.add(rdLoc(a))
      params.add(", ")
    let load = "\t$1 = ($2) ($3$4));$n" %
        [tmp, getTypeDesc(m, sym.typ), params, makeCString($extname)]
    var last = lastSon(n)
    if last.kind == nkHiddenStdConv: last = last.sons[1]
    internalAssert(last.kind == nkStrLit)
    let idx = last.strVal
    if idx.len == 0:
      add(m.initProc.s(cpsStmts), load)
    elif idx.len == 1 and idx[0] in {'0'..'9'}:
      add(m.extensionLoaders[idx[0]], load)
    else:
      internalError(sym.info, "wrong index: " & idx)
  else:
    appcg(m, m.s[cfsDynLibInit],
        "\t$1 = ($2) #nimGetProcAddr($3, $4);$n",
        [tmp, getTypeDesc(m, sym.typ), lib.name, makeCString($extname)])
  addf(m.s[cfsVars], "$2 $1;$n", [sym.loc.r, getTypeDesc(m, sym.loc.t)])

proc varInDynamicLib(m: BModule, sym: PSym) =
  var lib = sym.annex
  var extname = sym.loc.r
  loadDynamicLib(m, lib)
  incl(sym.loc.flags, lfIndirect)
  var tmp = mangleDynLibProc(sym)
  sym.loc.r = tmp             # from now on we only need the internal name
  inc(m.labels, 2)
  appcg(m, m.s[cfsDynLibInit],
      "$1 = ($2*) #nimGetProcAddr($3, $4);$n",
      [tmp, getTypeDesc(m, sym.typ), lib.name, makeCString($extname)])
  addf(m.s[cfsVars], "$2* $1;$n",
      [sym.loc.r, getTypeDesc(m, sym.loc.t)])

proc symInDynamicLibPartial(m: BModule, sym: PSym) =
  sym.loc.r = mangleDynLibProc(sym)
  sym.typ.sym = nil           # generate a new name

proc cgsym(m: BModule, name: string): Rope =
  var sym = magicsys.getCompilerProc(name)
  if sym != nil:
    case sym.kind
    of skProc, skMethod, skConverter, skIterators: genProc(m, sym)
    of skVar, skResult, skLet: genVarPrototype(m, sym)
    of skType: discard getTypeDesc(m, sym.typ)
    else: internalError("cgsym: " & name & ": " & $sym.kind)
  else:
    # we used to exclude the system module from this check, but for DLL
    # generation support this sloppyness leads to hard to detect bugs, so
    # we're picky here for the system module too:
    rawMessage(errSystemNeeds, name)
  result = sym.loc.r

proc generateHeaders(m: BModule) =
  add(m.s[cfsHeaders], tnl & "#include \"nimbase.h\"" & tnl)
  var it = PStrEntry(m.headerFiles.head)
  while it != nil:
    if it.data[0] == '#':
      add(m.s[cfsHeaders], rope(it.data.replace('`', '"') & tnl))
    elif it.data[0] notin {'\"', '<'}:
      addf(m.s[cfsHeaders], "#include \"$1\"$N", [rope(it.data)])
    else:
      addf(m.s[cfsHeaders], "#include $1$N", [rope(it.data)])
    it = PStrEntry(it.next)

proc retIsNotVoid(s: PSym): bool =
  result = (s.typ.sons[0] != nil) and not isInvalidReturnType(s.typ.sons[0])

proc initFrame(p: BProc, procname, filename: Rope): Rope =
  discard cgsym(p.module, "nimFrame")
  if p.maxFrameLen > 0:
    discard cgsym(p.module, "VarSlot")
    result = rfmt(nil, "\tnimfrs($1, $2, $3, $4)$N",
                  procname, filename, p.maxFrameLen.rope,
                  p.blocks[0].frameLen.rope)
  else:
    result = rfmt(nil, "\tnimfr($1, $2)$N", procname, filename)

proc deinitFrame(p: BProc): Rope =
  result = rfmt(p.module, "\t#popFrame();$n")

proc closureSetup(p: BProc, prc: PSym) =
  if tfCapturesEnv notin prc.typ.flags: return
  # prc.ast[paramsPos].last contains the type we're after:
  var ls = lastSon(prc.ast[paramsPos])
  if ls.kind != nkSym:
    internalError(prc.info, "closure generation failed")
  var env = ls.sym
  #echo "created environment: ", env.id, " for ", prc.name.s
  assignLocalVar(p, env)
  # generate cast assignment:
  linefmt(p, cpsStmts, "$1 = ($2) ClEnv;$n",
          rdLoc(env.loc), getTypeDesc(p.module, env.typ))

proc genProcAux(m: BModule, prc: PSym) =
  var p = newProc(prc, m)
  var header = genProcHeader(m, prc)
  var returnStmt: Rope = nil
  assert(prc.ast != nil)
  if sfPure notin prc.flags and prc.typ.sons[0] != nil:
    if resultPos >= prc.ast.len:
      internalError(prc.info, "proc has no result symbol")
    var res = prc.ast.sons[resultPos].sym # get result symbol
    if not isInvalidReturnType(prc.typ.sons[0]):
      if sfNoInit in prc.flags: incl(res.flags, sfNoInit)
      # declare the result symbol:
      assignLocalVar(p, res)
      assert(res.loc.r != nil)
      returnStmt = rfmt(nil, "\treturn $1;$n", rdLoc(res.loc))
      initLocalVar(p, res, immediateAsgn=false)
    else:
      fillResult(res)
      assignParam(p, res)
      if skipTypes(res.typ, abstractInst).kind == tyArray:
        incl(res.loc.flags, lfIndirect)
        res.loc.s = OnUnknown

  for i in countup(1, sonsLen(prc.typ.n) - 1):
    var param = prc.typ.n.sons[i].sym
    if param.typ.isCompileTimeOnly: continue
    assignParam(p, param)
  closureSetup(p, prc)
  genStmts(p, prc.getBody) # modifies p.locals, p.init, etc.
  var generatedProc: Rope
  if sfNoReturn in prc.flags:
    if hasDeclspec in extccomp.CC[extccomp.cCompiler].props:
      header = "__declspec(noreturn) " & header
  if sfPure in prc.flags:
    if hasDeclspec in extccomp.CC[extccomp.cCompiler].props:
      header = "__declspec(naked) " & header
    generatedProc = rfmt(nil, "$N$1 {$n$2$3$4}$N$N",
                         header, p.s(cpsLocals), p.s(cpsInit), p.s(cpsStmts))
  else:
    generatedProc = rfmt(nil, "$N$1 {$N", header)
    add(generatedProc, initGCFrame(p))
    if optStackTrace in prc.options:
      add(generatedProc, p.s(cpsLocals))
      var procname = makeCString(prc.name.s)
      add(generatedProc, initFrame(p, procname, prc.info.quotedFilename))
    else:
      add(generatedProc, p.s(cpsLocals))
    if optProfiler in prc.options:
      # invoke at proc entry for recursion:
      appcg(p, cpsInit, "\t#nimProfile();$n", [])
    if p.beforeRetNeeded: add(generatedProc, "{")
    add(generatedProc, p.s(cpsInit))
    add(generatedProc, p.s(cpsStmts))
    if p.beforeRetNeeded: add(generatedProc, ~"\t}BeforeRet: ;$n")
    add(generatedProc, deinitGCFrame(p))
    if optStackTrace in prc.options: add(generatedProc, deinitFrame(p))
    add(generatedProc, returnStmt)
    add(generatedProc, ~"}$N")
  add(m.s[cfsProcs], generatedProc)

proc crossesCppBoundary(m: BModule; sym: PSym): bool {.inline.} =
  result = sfCompileToCpp in m.module.flags and
           sfCompileToCpp notin sym.getModule().flags and
           gCmd != cmdCompileToCpp

proc genProcPrototype(m: BModule, sym: PSym) =
  useHeader(m, sym)
  if lfNoDecl in sym.loc.flags: return
  if lfDynamicLib in sym.loc.flags:
    if getModule(sym).id != m.module.id and
        not containsOrIncl(m.declaredThings, sym.id):
      add(m.s[cfsVars], rfmt(nil, "extern $1 $2;$n",
                        getTypeDesc(m, sym.loc.t), mangleDynLibProc(sym)))
  elif not containsOrIncl(m.declaredProtos, sym.id):
    var header = genProcHeader(m, sym)
    if sfNoReturn in sym.flags and hasDeclspec in extccomp.CC[cCompiler].props:
      header = "__declspec(noreturn) " & header
    if sym.typ.callConv != ccInline and crossesCppBoundary(m, sym):
      header = "extern \"C\" " & header
    if sfPure in sym.flags and hasAttribute in CC[cCompiler].props:
      header.add(" __attribute__((naked))")
    if sfNoReturn in sym.flags and hasAttribute in CC[cCompiler].props:
      header.add(" __attribute__((noreturn))")
    add(m.s[cfsProcHeaders], rfmt(nil, "$1;$n", header))

proc genProcNoForward(m: BModule, prc: PSym) =
  fillProcLoc(prc)
  useHeader(m, prc)
  if lfImportCompilerProc in prc.loc.flags:
    # dependency to a compilerproc:
    discard cgsym(m, prc.name.s)
    return
  genProcPrototype(m, prc)
  if lfNoDecl in prc.loc.flags: discard
  elif prc.typ.callConv == ccInline:
    # We add inline procs to the calling module to enable C based inlining.
    # This also means that a check with ``q.declaredThings`` is wrong, we need
    # a check for ``m.declaredThings``.
    if not containsOrIncl(m.declaredThings, prc.id): genProcAux(m, prc)
  elif lfDynamicLib in prc.loc.flags:
    var q = findPendingModule(m, prc)
    if q != nil and not containsOrIncl(q.declaredThings, prc.id):
      symInDynamicLib(q, prc)
    else:
      symInDynamicLibPartial(m, prc)
  elif sfImportc notin prc.flags:
    var q = findPendingModule(m, prc)
    if q != nil and not containsOrIncl(q.declaredThings, prc.id):
      genProcAux(q, prc)

proc requestConstImpl(p: BProc, sym: PSym) =
  var m = p.module
  useHeader(m, sym)
  if sym.loc.k == locNone:
    fillLoc(sym.loc, locData, sym.typ, mangleName(sym), OnStatic)
  if lfNoDecl in sym.loc.flags: return
  # declare implementation:
  var q = findPendingModule(m, sym)
  if q != nil and not containsOrIncl(q.declaredThings, sym.id):
    assert q.initProc.module == q
    addf(q.s[cfsData], "NIM_CONST $1 $2 = $3;$n",
        [getTypeDesc(q, sym.typ), sym.loc.r, genConstExpr(q.initProc, sym.ast)])
  # declare header:
  if q != m and not containsOrIncl(m.declaredThings, sym.id):
    assert(sym.loc.r != nil)
    let headerDecl = "extern NIM_CONST $1 $2;$n" %
        [getTypeDesc(m, sym.loc.t), sym.loc.r]
    add(m.s[cfsData], headerDecl)
    if sfExportc in sym.flags and generatedHeader != nil:
      add(generatedHeader.s[cfsData], headerDecl)

proc isActivated(prc: PSym): bool = prc.typ != nil

proc genProc(m: BModule, prc: PSym) =
  if sfBorrow in prc.flags or not isActivated(prc): return
  fillProcLoc(prc)
  if sfForward in prc.flags: addForwardedProc(m, prc)
  else:
    genProcNoForward(m, prc)
    if {sfExportc, sfCompilerProc} * prc.flags == {sfExportc} and
        generatedHeader != nil and lfNoDecl notin prc.loc.flags:
      genProcPrototype(generatedHeader, prc)
      if prc.typ.callConv == ccInline:
        if not containsOrIncl(generatedHeader.declaredThings, prc.id):
          genProcAux(generatedHeader, prc)

proc genVarPrototypeAux(m: BModule, sym: PSym) =
  assert(sfGlobal in sym.flags)
  useHeader(m, sym)
  fillLoc(sym.loc, locGlobalVar, sym.typ, mangleName(sym), OnHeap)
  if (lfNoDecl in sym.loc.flags) or containsOrIncl(m.declaredThings, sym.id):
    return
  if sym.owner.id != m.module.id:
    # else we already have the symbol generated!
    assert(sym.loc.r != nil)
    if sfThread in sym.flags:
      declareThreadVar(m, sym, true)
    else:
      add(m.s[cfsVars], "extern ")
      add(m.s[cfsVars], getTypeDesc(m, sym.loc.t))
      if lfDynamicLib in sym.loc.flags: add(m.s[cfsVars], "*")
      if sfRegister in sym.flags: add(m.s[cfsVars], " register")
      if sfVolatile in sym.flags: add(m.s[cfsVars], " volatile")
      addf(m.s[cfsVars], " $1;$n", [sym.loc.r])

proc genVarPrototype(m: BModule, sym: PSym) =
  genVarPrototypeAux(m, sym)

proc addIntTypes(result: var Rope) {.inline.} =
  addf(result, "#define NIM_INTBITS $1" & tnl, [
    platform.CPU[targetCPU].intSize.rope])

proc getCopyright(cfile: string): Rope =
  if optCompileOnly in gGlobalOptions:
    result = ("/* Generated by Nim Compiler v$1 */$N" &
        "/*   (c) 2015 Andreas Rumpf */$N" &
        "/* The generated code is subject to the original license. */$N") %
        [rope(VersionAsString)]
  else:
    result = ("/* Generated by Nim Compiler v$1 */$N" &
        "/*   (c) 2015 Andreas Rumpf */$N" &
        "/* The generated code is subject to the original license. */$N" &
        "/* Compiled for: $2, $3, $4 */$N" &
        "/* Command for C compiler:$n   $5 */$N") %
        [rope(VersionAsString),
        rope(platform.OS[targetOS].name),
        rope(platform.CPU[targetCPU].name),
        rope(extccomp.CC[extccomp.cCompiler].name),
        rope(getCompileCFileCmd(cfile))]

proc getFileHeader(cfile: string): Rope =
  result = getCopyright(cfile)
  addIntTypes(result)

proc genFilenames(m: BModule): Rope =
  discard cgsym(m, "dbgRegisterFilename")
  result = nil
  for i in 0.. <fileInfos.len:
    result.addf("dbgRegisterFilename($1);$N", [fileInfos[i].projPath.makeCString])

proc genMainProc(m: BModule) =
  const
    # The use of a volatile function pointer to call Pre/NimMainInner
    # prevents inlining of the NimMainInner function and dependent
    # functions, which might otherwise merge their stack frames.
    PreMainBody =
      "void PreMainInner() {$N" &
      "\tsystemInit000();$N" &
      "$1" &
      "$2" &
      "$3" &
      "}$N$N" &
      "void PreMain() {$N" &
      "\tvoid (*volatile inner)();$N" &
      "\tsystemDatInit000();$N" &
      "\tinner = PreMainInner;$N" &
      "$4$5" &
      "\t(*inner)();$N" &
      "}$N$N"

    MainProcs =
      "\tNimMain();$N"

    MainProcsWithResult =
      MainProcs & "\treturn nim_program_result;$N"

    NimMainBody =
      "N_CDECL(void, NimMainInner)(void) {$N" &
        "$1" &
      "}$N$N" &
      "N_CDECL(void, NimMain)(void) {$N" &
        "\tvoid (*volatile inner)();$N" &
        "\tPreMain();$N" &
        "\tinner = NimMainInner;$N" &
        "$2" &
        "\t(*inner)();$N" &
      "}$N$N"

    PosixNimMain =
      "int cmdCount;$N" &
      "char** cmdLine;$N" &
      "char** gEnv;$N" &
      NimMainBody

    PosixCMain =
      "int main(int argc, char** args, char** env) {$N" &
        "\tcmdLine = args;$N" &
        "\tcmdCount = argc;$N" &
        "\tgEnv = env;$N" &
        MainProcsWithResult &
      "}$N$N"

    StandaloneCMain =
      "int main(void) {$N" &
        MainProcs &
        "\treturn 0;$N" &
      "}$N$N"

    WinNimMain = NimMainBody

    WinCMain = "N_STDCALL(int, WinMain)(HINSTANCE hCurInstance, $N" &
      "                        HINSTANCE hPrevInstance, $N" &
      "                        LPSTR lpCmdLine, int nCmdShow) {$N" &
      MainProcsWithResult & "}$N$N"

    WinNimDllMain = "N_LIB_EXPORT " & NimMainBody

    WinCDllMain =
      "BOOL WINAPI DllMain(HINSTANCE hinstDLL, DWORD fwdreason, $N" &
      "                    LPVOID lpvReserved) {$N" &
      "\tif(fwdreason == DLL_PROCESS_ATTACH) {$N" & MainProcs & "}$N" &
      "\treturn 1;$N}$N$N"

    PosixNimDllMain = WinNimDllMain

    PosixCDllMain =
      "void NIM_POSIX_INIT NimMainInit(void) {$N" &
        MainProcs &
      "}$N$N"

  var nimMain, otherMain: FormatStr
  if platform.targetOS == osWindows and
      gGlobalOptions * {optGenGuiApp, optGenDynLib} != {}:
    if optGenGuiApp in gGlobalOptions:
      nimMain = WinNimMain
      otherMain = WinCMain
    else:
      nimMain = WinNimDllMain
      otherMain = WinCDllMain
    discard lists.includeStr(m.headerFiles, "<windows.h>")
  elif optGenDynLib in gGlobalOptions:
    nimMain = PosixNimDllMain
    otherMain = PosixCDllMain
  elif platform.targetOS == osStandalone:
    nimMain = PosixNimMain
    otherMain = StandaloneCMain
  else:
    nimMain = PosixNimMain
    otherMain = PosixCMain
  if gBreakpoints != nil: discard cgsym(m, "dbgRegisterBreakpoint")
  if optEndb in gOptions:
    gBreakpoints.add(m.genFilenames)

  let initStackBottomCall =
    if platform.targetOS == osStandalone or gSelectedGC == gcNone: "".rope
    else: ropecg(m, "\t#initStackBottomWith((void *)&inner);$N")
  inc(m.labels)
  appcg(m, m.s[cfsProcs], PreMainBody, [
    mainDatInit, gBreakpoints, otherModsInit,
     if emulatedThreadVars() and platform.targetOS != osStandalone:
       ropecg(m, "\t#initThreadVarsEmulation();$N")
     else:
       "".rope,
     initStackBottomCall])

  appcg(m, m.s[cfsProcs], nimMain, [mainModInit, initStackBottomCall, rope(m.labels)])
  if optNoMain notin gGlobalOptions:
    appcg(m, m.s[cfsProcs], otherMain, [])

proc getSomeInitName(m: PSym, suffix: string): Rope =
  assert m.kind == skModule
  assert m.owner.kind == skPackage
  if {sfSystemModule, sfMainModule} * m.flags == {}:
    result = m.owner.name.s.mangle.rope
    result.add "_"
  result.add m.name.s
  result.add suffix

proc getInitName(m: PSym): Rope = getSomeInitName(m, "Init000")
proc getDatInitName(m: PSym): Rope = getSomeInitName(m, "DatInit000")

proc registerModuleToMain(m: PSym) =
  var
    init = m.getInitName
    datInit = m.getDatInitName
  addf(mainModProcs, "NIM_EXTERNC N_NOINLINE(void, $1)(void);$N", [init])
  addf(mainModProcs, "NIM_EXTERNC N_NOINLINE(void, $1)(void);$N", [datInit])
  if sfSystemModule notin m.flags:
    addf(mainDatInit, "\t$1();$N", [datInit])
    let initCall = "\t$1();$N" % [init]
    if sfMainModule in m.flags:
      add(mainModInit, initCall)
    else:
      add(otherModsInit, initCall)

proc genInitCode(m: BModule) =
  var initname = getInitName(m.module)
  var prc = "NIM_EXTERNC N_NOINLINE(void, $1)(void) {$N" % [initname]
  if m.typeNodes > 0:
    appcg(m, m.s[cfsTypeInit1], "static #TNimNode $1[$2];$n",
          [m.typeNodesName, rope(m.typeNodes)])
  if m.nimTypes > 0:
    appcg(m, m.s[cfsTypeInit1], "static #TNimType $1[$2];$n",
          [m.nimTypesName, rope(m.nimTypes)])

  add(prc, initGCFrame(m.initProc))

  add(prc, genSectionStart(cpsLocals))
  add(prc, m.preInitProc.s(cpsLocals))
  add(prc, m.initProc.s(cpsLocals))
  add(prc, m.postInitProc.s(cpsLocals))
  add(prc, genSectionEnd(cpsLocals))

  if optStackTrace in m.initProc.options and not m.frameDeclared:
    # BUT: the generated init code might depend on a current frame, so
    # declare it nevertheless:
    m.frameDeclared = true
    if not m.preventStackTrace:
      var procname = makeCString(m.module.name.s)
      add(prc, initFrame(m.initProc, procname, m.module.info.quotedFilename))
    else:
      add(prc, ~"\tTFrame F; FR.len = 0;$N")

  add(prc, genSectionStart(cpsInit))
  add(prc, m.preInitProc.s(cpsInit))
  add(prc, m.initProc.s(cpsInit))
  add(prc, m.postInitProc.s(cpsInit))
  add(prc, genSectionEnd(cpsInit))

  add(prc, genSectionStart(cpsStmts))
  add(prc, m.preInitProc.s(cpsStmts))
  add(prc, m.initProc.s(cpsStmts))
  add(prc, m.postInitProc.s(cpsStmts))
  add(prc, genSectionEnd(cpsStmts))
  if optStackTrace in m.initProc.options and not m.preventStackTrace:
    add(prc, deinitFrame(m.initProc))
  add(prc, deinitGCFrame(m.initProc))
  addf(prc, "}$N$N", [])

  prc.addf("NIM_EXTERNC N_NOINLINE(void, $1)(void) {$N",
           [getDatInitName(m.module)])

  for i in cfsTypeInit1..cfsDynLibInit:
    add(prc, genSectionStart(i))
    add(prc, m.s[i])
    add(prc, genSectionEnd(i))

  addf(prc, "}$N$N", [])
  # we cannot simply add the init proc to ``m.s[cfsProcs]`` anymore because
  # that would lead to a *nesting* of merge sections which the merger does
  # not support. So we add it to another special section: ``cfsInitProc``
  add(m.s[cfsInitProc], prc)

  for i, el in pairs(m.extensionLoaders):
    if el != nil:
      let ex = "N_NIMCALL(void, nimLoadProcs$1)(void) {$2}$N$N" %
        [(i.ord - '0'.ord).rope, el]
      add(m.s[cfsInitProc], ex)

proc genModule(m: BModule, cfile: string): Rope =
  result = getFileHeader(cfile)
  result.add(genMergeInfo(m))

  generateHeaders(m)

  generateThreadLocalStorage(m)
  for i in countup(cfsHeaders, cfsProcs):
    add(result, genSectionStart(i))
    add(result, m.s[i])
    add(result, genSectionEnd(i))
  add(result, m.s[cfsInitProc])

proc newPreInitProc(m: BModule): BProc =
  result = newProc(nil, m)
  # little hack so that unique temporaries are generated:
  result.labels = 100_000

proc newPostInitProc(m: BModule): BProc =
  result = newProc(nil, m)
  # little hack so that unique temporaries are generated:
  result.labels = 200_000

proc initProcOptions(m: BModule): TOptions =
  if sfSystemModule in m.module.flags: gOptions-{optStackTrace} else: gOptions

proc rawNewModule(module: PSym, filename: string): BModule =
  new(result)
  initLinkedList(result.headerFiles)
  result.declaredThings = initIntSet()
  result.declaredProtos = initIntSet()
  result.cfilename = filename
  result.filename = filename
  initIdTable(result.typeCache)
  initIdTable(result.forwTypeCache)
  result.module = module
  result.typeInfoMarker = initIntSet()
  result.initProc = newProc(nil, result)
  result.initProc.options = initProcOptions(result)
  result.preInitProc = newPreInitProc(result)
  result.postInitProc = newPostInitProc(result)
  initNodeTable(result.dataCache)
  result.typeStack = @[]
  result.forwardedProcs = @[]
  result.typeNodesName = getTempName()
  result.nimTypesName = getTempName()
  # no line tracing for the init sections of the system module so that we
  # don't generate a TFrame which can confuse the stack botton initialization:
  if sfSystemModule in module.flags:
    result.preventStackTrace = true
    excl(result.preInitProc.options, optStackTrace)
    excl(result.postInitProc.options, optStackTrace)

proc nullify[T](arr: var T) =
  for i in low(arr)..high(arr):
    arr[i] = Rope(nil)

proc resetModule*(m: BModule) =
  # between two compilations in CAAS mode, we can throw
  # away all the data that was written to disk
  initLinkedList(m.headerFiles)
  m.declaredProtos = initIntSet()
  initIdTable(m.forwTypeCache)
  m.initProc = newProc(nil, m)
  m.initProc.options = initProcOptions(m)
  m.preInitProc = newPreInitProc(m)
  m.postInitProc = newPostInitProc(m)
  initNodeTable(m.dataCache)
  m.typeStack = @[]
  m.forwardedProcs = @[]
  m.typeNodesName = getTempName()
  m.nimTypesName = getTempName()
  m.preventStackTrace = sfSystemModule in m.module.flags
  nullify m.s
  m.usesThreadVars = false
  m.typeNodes = 0
  m.nimTypes = 0
  nullify m.extensionLoaders

  # indicate that this is now cached module
  # the cache will be invalidated by nullifying gModules
  m.fromCache = true

  # we keep only the "merge info" information for the module
  # and the properties that can't change:
  # m.filename
  # m.cfilename
  # m.isHeaderFile
  # m.module ?
  # m.typeCache
  # m.declaredThings
  # m.typeInfoMarker
  # m.labels
  # m.FrameDeclared

proc resetCgenModules* =
  for m in cgenModules(): resetModule(m)

proc rawNewModule(module: PSym): BModule =
  result = rawNewModule(module, module.position.int32.toFullPath)

proc newModule(module: PSym): BModule =
  # we should create only one cgen module for each module sym
  internalAssert getCgenModule(module) == nil

  result = rawNewModule(module)
  growCache gModules, module.position
  gModules[module.position] = result

  if (optDeadCodeElim in gGlobalOptions):
    if (sfDeadCodeElim in module.flags):
      internalError("added pending module twice: " & module.filename)

proc myOpen(module: PSym): PPassContext =
  result = newModule(module)
  if optGenIndex in gGlobalOptions and generatedHeader == nil:
    let f = if headerFile.len > 0: headerFile else: gProjectFull
    generatedHeader = rawNewModule(module,
      changeFileExt(completeCFilePath(f), hExt))
    generatedHeader.isHeaderFile = true

proc writeHeader(m: BModule) =
  var result = getCopyright(m.filename)
  var guard = "__$1__" % [m.filename.splitFile.name.rope]
  result.addf("#ifndef $1$n#define $1$n", [guard])
  addIntTypes(result)
  generateHeaders(m)

  generateThreadLocalStorage(m)
  for i in countup(cfsHeaders, cfsProcs):
    add(result, genSectionStart(i))
    add(result, m.s[i])
    add(result, genSectionEnd(i))
  add(result, m.s[cfsInitProc])

  if optGenDynLib in gGlobalOptions:
    result.add("N_LIB_IMPORT ")
  result.addf("N_CDECL(void, NimMain)(void);$n", [])
  result.addf("#endif /* $1 */$n", [guard])
  writeRope(result, m.filename)

proc getCFile(m: BModule): string =
  let ext =
      if m.compileToCpp: ".cpp"
      elif gCmd == cmdCompileToOC or sfCompileToObjC in m.module.flags: ".m"
      else: ".c"
  result = changeFileExt(completeCFilePath(m.cfilename.withPackageName), ext)

proc myOpenCached(module: PSym, rd: PRodReader): PPassContext =
  assert optSymbolFiles in gGlobalOptions
  var m = newModule(module)
  readMergeInfo(getCFile(m), m)
  result = m

proc myProcess(b: PPassContext, n: PNode): PNode =
  result = n
  if b == nil or passes.skipCodegen(n): return
  var m = BModule(b)
  m.initProc.options = initProcOptions(m)
  genStmts(m.initProc, n)

proc finishModule(m: BModule) =
  var i = 0
  while i <= high(m.forwardedProcs):
    # Note: ``genProc`` may add to ``m.forwardedProcs``, so we cannot use
    # a ``for`` loop here
    var prc = m.forwardedProcs[i]
    if sfForward in prc.flags:
      internalError(prc.info, "still forwarded: " & prc.name.s)
    genProcNoForward(m, prc)
    inc(i)
  assert(gForwardedProcsCounter >= i)
  dec(gForwardedProcsCounter, i)
  setLen(m.forwardedProcs, 0)

proc shouldRecompile(code: Rope, cfile: string): bool =
  result = true
  if optForceFullMake notin gGlobalOptions:
    var objFile = toObjFile(cfile)
    if writeRopeIfNotEqual(code, cfile): return
    if existsFile(objFile) and os.fileNewer(objFile, cfile): result = false
  else:
    writeRope(code, cfile)

# We need 2 different logics here: pending modules (including
# 'nim__dat') may require file merging for the combination of dead code
# elimination and incremental compilation! Non pending modules need no
# such logic and in fact the logic hurts for the main module at least;
# it would generate multiple 'main' procs, for instance.

proc writeModule(m: BModule, pending: bool) =
  # generate code for the init statements of the module:
  var cfile = getCFile(m)
  var cfilenoext = changeFileExt(cfile, "")

  if not m.fromCache or optForceFullMake in gGlobalOptions:
    genInitCode(m)
    finishTypeDescriptions(m)
    if sfMainModule in m.module.flags:
      # generate main file:
      add(m.s[cfsProcHeaders], mainModProcs)
      generateThreadVarsSize(m)

    var code = genModule(m, cfile)
    when hasTinyCBackend:
      if gCmd == cmdRun:
        tccgen.compileCCode($code)
        return

    if shouldRecompile(code, cfile):
      addFileToCompile(cfile)
  elif pending and mergeRequired(m) and sfMainModule notin m.module.flags:
    mergeFiles(cfile, m)
    genInitCode(m)
    finishTypeDescriptions(m)
    var code = genModule(m, cfile)
    writeRope(code, cfile)
    addFileToCompile(cfile)
  elif not existsFile(toObjFile(cfilenoext)):
    # Consider: first compilation compiles ``system.nim`` and produces
    # ``system.c`` but then compilation fails due to an error. This means
    # that ``system.o`` is missing, so we need to call the C compiler for it:
    addFileToCompile(cfile)

  addFileToLink(cfilenoext)

proc updateCachedModule(m: BModule) =
  let cfile = getCFile(m)
  let cfilenoext = changeFileExt(cfile, "")

  if mergeRequired(m) and sfMainModule notin m.module.flags:
    mergeFiles(cfile, m)
    genInitCode(m)
    finishTypeDescriptions(m)
    var code = genModule(m, cfile)
    writeRope(code, cfile)
    addFileToCompile(cfile)

  addFileToLink(cfilenoext)

proc myClose(b: PPassContext, n: PNode): PNode =
  result = n
  if b == nil or passes.skipCodegen(n): return
  var m = BModule(b)
  if n != nil:
    m.initProc.options = initProcOptions(m)
    genStmts(m.initProc, n)
  # cached modules need to registered too:
  registerModuleToMain(m.module)

  if sfMainModule in m.module.flags:
    m.objHasKidsValid = true
    var disp = generateMethodDispatchers()
    for i in 0..sonsLen(disp)-1: genProcAux(m, disp.sons[i].sym)
    genMainProc(m)

proc cgenWriteModules* =
  # we need to process the transitive closure because recursive module
  # deps are allowed (and the system module is processed in the wrong
  # order anyway)
  if generatedHeader != nil: finishModule(generatedHeader)
  while gForwardedProcsCounter > 0:
    for m in cgenModules():
      if not m.fromCache:
        finishModule(m)
  for m in cgenModules():
    if m.fromCache:
      m.updateCachedModule
    else:
      m.writeModule(pending=true)
  writeMapping(gMapping)
  if generatedHeader != nil: writeHeader(generatedHeader)

const cgenPass* = makePass(myOpen, myOpenCached, myProcess, myClose)

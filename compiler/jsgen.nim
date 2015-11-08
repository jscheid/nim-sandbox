#
#
#           The Nim Compiler
#        (c) Copyright 2015 Andreas Rumpf
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.
#

# This is the JavaScript code generator.
# Soon also a Luajit code generator. ;-)

discard """
The JS code generator contains only 2 tricks:

Trick 1
-------
Some locations (for example 'var int') require "fat pointers" (``etyBaseIndex``)
which are pairs (array, index). The derefence operation is then 'array[index]'.
Check ``mapType`` for the details.

Trick 2
-------
It is preferable to generate '||' and '&&' if possible since that is more
idiomatic and hence should be friendlier for the JS JIT implementation. However
code like ``foo and (let bar = baz())`` cannot be translated this way. Instead
the expressions need to be transformed into statements. ``isSimpleExpr``
implements the required case distinction.
"""


import
  ast, astalgo, strutils, hashes, trees, platform, magicsys, extccomp, options,
  nversion, nimsets, msgs, securehash, bitsets, idents, lists, types, os,
  times, ropes, math, passes, ccgutils, wordrecg, renderer, rodread, rodutils,
  intsets, cgmeth, lowerings

type
  TTarget = enum
    targetJS, targetLua
  TJSGen = object of TPassContext
    module: PSym

  BModule = ref TJSGen
  TJSTypeKind = enum       # necessary JS "types"
    etyNone,                  # no type
    etyNull,                  # null type
    etyProc,                  # proc type
    etyBool,                  # bool type
    etyInt,                   # JavaScript's int
    etyFloat,                 # JavaScript's float
    etyString,                # JavaScript's string
    etyObject,                # JavaScript's reference to an object
    etyBaseIndex              # base + index needed
  TResKind = enum
    resNone,                  # not set
    resExpr,                  # is some complex expression
    resVal                    # is a temporary/value/l-value
  TCompRes = object
    kind: TResKind
    typ: TJSTypeKind
    res: Rope               # result part; index if this is an
                             # (address, index)-tuple
    address: Rope           # address of an (address, index)-tuple

  TBlock = object
    id: int                  # the ID of the label; positive means that it
                             # has been used (i.e. the label should be emitted)
    isLoop: bool             # whether it's a 'block' or 'while'

  TGlobals = object
    typeInfo, code: Rope
    forwarded: seq[PSym]
    generatedSyms: IntSet
    typeInfoGenerated: IntSet

  PGlobals = ref TGlobals
  PProc = ref TProc
  TProc = object
    procDef: PNode
    prc: PSym
    locals, body: Rope
    options: TOptions
    module: BModule
    g: PGlobals
    beforeRetNeeded: bool
    target: TTarget # duplicated here for faster dispatching
    unique: int    # for temp identifier generation
    blocks: seq[TBlock]
    up: PProc     # up the call chain; required for closure support

template `|`(a, b: expr): expr {.immediate, dirty.} =
  (if p.target == targetJS: a else: b)

proc newGlobals(): PGlobals =
  new(result)
  result.forwarded = @[]
  result.generatedSyms = initIntSet()
  result.typeInfoGenerated = initIntSet()

proc initCompRes(r: var TCompRes) =
  r.address = nil
  r.res = nil
  r.typ = etyNone
  r.kind = resNone

proc rdLoc(a: TCompRes): Rope {.inline.} =
  result = a.res
  when false:
    if a.typ != etyBaseIndex:
      result = a.res
    else:
      result = "$1[$2]" % [a.address, a.res]

proc newProc(globals: PGlobals, module: BModule, procDef: PNode,
             options: TOptions): PProc =
  result = PProc(
    blocks: @[],
    options: options,
    module: module,
    procDef: procDef,
    g: globals)
  if procDef != nil: result.prc = procDef.sons[namePos].sym

const
  MappedToObject = {tyObject, tyArray, tyArrayConstr, tyTuple, tyOpenArray,
    tySet, tyBigNum, tyVarargs}

proc mapType(typ: PType): TJSTypeKind =
  let t = skipTypes(typ, abstractInst)
  case t.kind
  of tyVar, tyRef, tyPtr:
    if skipTypes(t.lastSon, abstractInst).kind in MappedToObject:
      result = etyObject
    else:
      result = etyBaseIndex
  of tyPointer:
    # treat a tyPointer like a typed pointer to an array of bytes
    result = etyBaseIndex
  of tyRange, tyDistinct, tyOrdinal, tyConst, tyMutable, tyIter, tyProxy:
    result = mapType(t.sons[0])
  of tyInt..tyInt64, tyUInt..tyUInt64, tyEnum, tyChar: result = etyInt
  of tyBool: result = etyBool
  of tyFloat..tyFloat128: result = etyFloat
  of tySet: result = etyObject # map a set to a table
  of tyString, tySequence: result = etyInt # little hack to get right semantics
  of tyObject, tyArray, tyArrayConstr, tyTuple, tyOpenArray, tyBigNum,
     tyVarargs:
    result = etyObject
  of tyNil: result = etyNull
  of tyGenericInst, tyGenericParam, tyGenericBody, tyGenericInvocation,
     tyNone, tyFromExpr, tyForward, tyEmpty, tyFieldAccessor,
     tyExpr, tyStmt, tyStatic, tyTypeDesc, tyTypeClasses:
    result = etyNone
  of tyProc: result = etyProc
  of tyCString: result = etyString

proc mangleName(s: PSym): Rope =
  result = s.loc.r
  if result == nil:
    result = rope(mangle(s.name.s))
    add(result, "_")
    add(result, rope(s.id))
    s.loc.r = result

proc makeJSString(s: string): Rope =
  (if s.isNil: "null".rope else: strutils.escape(s).rope)

include jstypes

proc gen(p: PProc, n: PNode, r: var TCompRes)
proc genStmt(p: PProc, n: PNode)
proc genProc(oldProc: PProc, prc: PSym): Rope
proc genConstant(p: PProc, c: PSym)

proc useMagic(p: PProc, name: string) =
  if name.len == 0: return
  var s = magicsys.getCompilerProc(name)
  if s != nil:
    internalAssert s.kind in {skProc, skMethod, skConverter}
    if not p.g.generatedSyms.containsOrIncl(s.id):
      add(p.g.code, genProc(p, s))
  else:
    # we used to exclude the system module from this check, but for DLL
    # generation support this sloppyness leads to hard to detect bugs, so
    # we're picky here for the system module too:
    if p.prc != nil: globalError(p.prc.info, errSystemNeeds, name)
    else: rawMessage(errSystemNeeds, name)

proc isSimpleExpr(n: PNode): bool =
  # calls all the way down --> can stay expression based
  if n.kind in nkCallKinds+{nkBracketExpr, nkBracket, nkCurly, nkDotExpr, nkPar,
                            nkObjConstr}:
    for c in n:
      if not c.isSimpleExpr: return false
    result = true
  elif n.isAtom:
    result = true

proc getTemp(p: PProc, defineInLocals: bool = true): Rope =
  inc(p.unique)
  result = "Tmp$1" % [rope(p.unique)]
  if defineInLocals: addf(p.locals, "var $1;$n" | "local $1;$n", [result])

proc genAnd(p: PProc, a, b: PNode, r: var TCompRes) =
  assert r.kind == resNone
  var x, y: TCompRes
  if a.isSimpleExpr and b.isSimpleExpr:
    gen(p, a, x)
    gen(p, b, y)
    r.kind = resExpr
    r.res = ("($1 && $2)" | "($1 and $2)") % [x.rdLoc, y.rdLoc]
  else:
    r.res = p.getTemp
    r.kind = resVal
    # while a and b:
    # -->
    # while true:
    #   aa
    #   if not a: tmp = false
    #   else:
    #     bb
    #     tmp = b
    # tmp
    gen(p, a, x)
    p.body.addf("if (!$1) $2 = false; else {" |
                "if not $1 then $2 = false; else", [x.rdLoc, r.rdLoc])
    gen(p, b, y)
    p.body.addf("$2 = $1; }" |
                "$2 = $1 end", [y.rdLoc, r.rdLoc])

proc genOr(p: PProc, a, b: PNode, r: var TCompRes) =
  assert r.kind == resNone
  var x, y: TCompRes
  if a.isSimpleExpr and b.isSimpleExpr:
    gen(p, a, x)
    gen(p, b, y)
    r.kind = resExpr
    r.res = ("($1 || $2)" | "($1 or $2)") % [x.rdLoc, y.rdLoc]
  else:
    r.res = p.getTemp
    r.kind = resVal
    gen(p, a, x)
    p.body.addf("if ($1) $2 = true; else {" |
                "if $1 then $2 = true; else", [x.rdLoc, r.rdLoc])
    gen(p, b, y)
    p.body.addf("$2 = $1; }" |
                "$2 = $1 end", [y.rdLoc, r.rdLoc])

type
  TMagicFrmt = array[0..3, string]
  TMagicOps = array[mAddI..mStrToStr, TMagicFrmt]

const # magic checked op; magic unchecked op; checked op; unchecked op
  jsOps: TMagicOps = [
    ["addInt", "", "addInt($1, $2)", "($1 + $2)"], # AddI
    ["subInt", "", "subInt($1, $2)", "($1 - $2)"], # SubI
    ["mulInt", "", "mulInt($1, $2)", "($1 * $2)"], # MulI
    ["divInt", "", "divInt($1, $2)", "Math.floor($1 / $2)"], # DivI
    ["modInt", "", "modInt($1, $2)", "Math.floor($1 % $2)"], # ModI
    ["addInt", "", "addInt($1, $2)", "($1 + $2)"], # Succ
    ["subInt", "", "subInt($1, $2)", "($1 - $2)"], # Pred
    ["", "", "($1 + $2)", "($1 + $2)"], # AddF64
    ["", "", "($1 - $2)", "($1 - $2)"], # SubF64
    ["", "", "($1 * $2)", "($1 * $2)"], # MulF64
    ["", "", "($1 / $2)", "($1 / $2)"], # DivF64
    ["", "", "($1 >>> $2)", "($1 >>> $2)"], # ShrI
    ["", "", "($1 << $2)", "($1 << $2)"], # ShlI
    ["", "", "($1 & $2)", "($1 & $2)"], # BitandI
    ["", "", "($1 | $2)", "($1 | $2)"], # BitorI
    ["", "", "($1 ^ $2)", "($1 ^ $2)"], # BitxorI
    ["nimMin", "nimMin", "nimMin($1, $2)", "nimMin($1, $2)"], # MinI
    ["nimMax", "nimMax", "nimMax($1, $2)", "nimMax($1, $2)"], # MaxI
    ["nimMin", "nimMin", "nimMin($1, $2)", "nimMin($1, $2)"], # MinF64
    ["nimMax", "nimMax", "nimMax($1, $2)", "nimMax($1, $2)"], # MaxF64
    ["addU", "addU", "addU($1, $2)", "addU($1, $2)"], # addU
    ["subU", "subU", "subU($1, $2)", "subU($1, $2)"], # subU
    ["mulU", "mulU", "mulU($1, $2)", "mulU($1, $2)"], # mulU
    ["divU", "divU", "divU($1, $2)", "divU($1, $2)"], # divU
    ["modU", "modU", "modU($1, $2)", "modU($1, $2)"], # modU
    ["", "", "($1 == $2)", "($1 == $2)"], # EqI
    ["", "", "($1 <= $2)", "($1 <= $2)"], # LeI
    ["", "", "($1 < $2)", "($1 < $2)"], # LtI
    ["", "", "($1 == $2)", "($1 == $2)"], # EqF64
    ["", "", "($1 <= $2)", "($1 <= $2)"], # LeF64
    ["", "", "($1 < $2)", "($1 < $2)"], # LtF64
    ["leU", "leU", "leU($1, $2)", "leU($1, $2)"], # leU
    ["ltU", "ltU", "ltU($1, $2)", "ltU($1, $2)"], # ltU
    ["leU64", "leU64", "leU64($1, $2)", "leU64($1, $2)"], # leU64
    ["ltU64", "ltU64", "ltU64($1, $2)", "ltU64($1, $2)"], # ltU64
    ["", "", "($1 == $2)", "($1 == $2)"], # EqEnum
    ["", "", "($1 <= $2)", "($1 <= $2)"], # LeEnum
    ["", "", "($1 < $2)", "($1 < $2)"], # LtEnum
    ["", "", "($1 == $2)", "($1 == $2)"], # EqCh
    ["", "", "($1 <= $2)", "($1 <= $2)"], # LeCh
    ["", "", "($1 < $2)", "($1 < $2)"], # LtCh
    ["", "", "($1 == $2)", "($1 == $2)"], # EqB
    ["", "", "($1 <= $2)", "($1 <= $2)"], # LeB
    ["", "", "($1 < $2)", "($1 < $2)"], # LtB
    ["", "", "($1 == $2)", "($1 == $2)"], # EqRef
    ["", "", "($1 == $2)", "($1 == $2)"], # EqUntracedRef
    ["", "", "($1 <= $2)", "($1 <= $2)"], # LePtr
    ["", "", "($1 < $2)", "($1 < $2)"], # LtPtr
    ["", "", "($1 == $2)", "($1 == $2)"], # EqCString
    ["", "", "($1 != $2)", "($1 != $2)"], # Xor
    ["", "", "($1 == $2)", "($1 == $2)"], # EqProc
    ["negInt", "", "negInt($1)", "-($1)"], # UnaryMinusI
    ["negInt64", "", "negInt64($1)", "-($1)"], # UnaryMinusI64
    ["absInt", "", "absInt($1)", "Math.abs($1)"], # AbsI
    ["", "", "!($1)", "!($1)"], # Not
    ["", "", "+($1)", "+($1)"], # UnaryPlusI
    ["", "", "~($1)", "~($1)"], # BitnotI
    ["", "", "+($1)", "+($1)"], # UnaryPlusF64
    ["", "", "-($1)", "-($1)"], # UnaryMinusF64
    ["", "", "Math.abs($1)", "Math.abs($1)"], # AbsF64
    ["Ze8ToI", "Ze8ToI", "Ze8ToI($1)", "Ze8ToI($1)"], # mZe8ToI
    ["Ze8ToI64", "Ze8ToI64", "Ze8ToI64($1)", "Ze8ToI64($1)"], # mZe8ToI64
    ["Ze16ToI", "Ze16ToI", "Ze16ToI($1)", "Ze16ToI($1)"], # mZe16ToI
    ["Ze16ToI64", "Ze16ToI64", "Ze16ToI64($1)", "Ze16ToI64($1)"], # mZe16ToI64
    ["Ze32ToI64", "Ze32ToI64", "Ze32ToI64($1)", "Ze32ToI64($1)"], # mZe32ToI64
    ["ZeIToI64", "ZeIToI64", "ZeIToI64($1)", "ZeIToI64($1)"], # mZeIToI64
    ["toU8", "toU8", "toU8($1)", "toU8($1)"], # toU8
    ["toU16", "toU16", "toU16($1)", "toU16($1)"], # toU16
    ["toU32", "toU32", "toU32($1)", "toU32($1)"], # toU32
    ["", "", "$1", "$1"],     # ToFloat
    ["", "", "$1", "$1"],     # ToBiggestFloat
    ["", "", "Math.floor($1)", "Math.floor($1)"], # ToInt
    ["", "", "Math.floor($1)", "Math.floor($1)"], # ToBiggestInt
    ["nimCharToStr", "nimCharToStr", "nimCharToStr($1)", "nimCharToStr($1)"],
    ["nimBoolToStr", "nimBoolToStr", "nimBoolToStr($1)", "nimBoolToStr($1)"], [
      "cstrToNimstr", "cstrToNimstr", "cstrToNimstr(($1)+\"\")",
      "cstrToNimstr(($1)+\"\")"], ["cstrToNimstr", "cstrToNimstr",
                                   "cstrToNimstr(($1)+\"\")",
                                   "cstrToNimstr(($1)+\"\")"], ["cstrToNimstr",
      "cstrToNimstr", "cstrToNimstr(($1)+\"\")", "cstrToNimstr(($1)+\"\")"],
    ["cstrToNimstr", "cstrToNimstr", "cstrToNimstr($1)", "cstrToNimstr($1)"],
    ["", "", "$1", "$1"]]

  luaOps: TMagicOps = [
    ["addInt", "", "addInt($1, $2)", "($1 + $2)"], # AddI
    ["subInt", "", "subInt($1, $2)", "($1 - $2)"], # SubI
    ["mulInt", "", "mulInt($1, $2)", "($1 * $2)"], # MulI
    ["divInt", "", "divInt($1, $2)", "Math.floor($1 / $2)"], # DivI
    ["modInt", "", "modInt($1, $2)", "Math.floor($1 % $2)"], # ModI
    ["addInt", "", "addInt($1, $2)", "($1 + $2)"], # Succ
    ["subInt", "", "subInt($1, $2)", "($1 - $2)"], # Pred
    ["", "", "($1 + $2)", "($1 + $2)"], # AddF64
    ["", "", "($1 - $2)", "($1 - $2)"], # SubF64
    ["", "", "($1 * $2)", "($1 * $2)"], # MulF64
    ["", "", "($1 / $2)", "($1 / $2)"], # DivF64
    ["", "", "($1 >>> $2)", "($1 >>> $2)"], # ShrI
    ["", "", "($1 << $2)", "($1 << $2)"], # ShlI
    ["", "", "($1 & $2)", "($1 & $2)"], # BitandI
    ["", "", "($1 | $2)", "($1 | $2)"], # BitorI
    ["", "", "($1 ^ $2)", "($1 ^ $2)"], # BitxorI
    ["nimMin", "nimMin", "nimMin($1, $2)", "nimMin($1, $2)"], # MinI
    ["nimMax", "nimMax", "nimMax($1, $2)", "nimMax($1, $2)"], # MaxI
    ["nimMin", "nimMin", "nimMin($1, $2)", "nimMin($1, $2)"], # MinF64
    ["nimMax", "nimMax", "nimMax($1, $2)", "nimMax($1, $2)"], # MaxF64
    ["addU", "addU", "addU($1, $2)", "addU($1, $2)"], # addU
    ["subU", "subU", "subU($1, $2)", "subU($1, $2)"], # subU
    ["mulU", "mulU", "mulU($1, $2)", "mulU($1, $2)"], # mulU
    ["divU", "divU", "divU($1, $2)", "divU($1, $2)"], # divU
    ["modU", "modU", "modU($1, $2)", "modU($1, $2)"], # modU
    ["", "", "($1 == $2)", "($1 == $2)"], # EqI
    ["", "", "($1 <= $2)", "($1 <= $2)"], # LeI
    ["", "", "($1 < $2)", "($1 < $2)"], # LtI
    ["", "", "($1 == $2)", "($1 == $2)"], # EqF64
    ["", "", "($1 <= $2)", "($1 <= $2)"], # LeF64
    ["", "", "($1 < $2)", "($1 < $2)"], # LtF64
    ["leU", "leU", "leU($1, $2)", "leU($1, $2)"], # leU
    ["ltU", "ltU", "ltU($1, $2)", "ltU($1, $2)"], # ltU
    ["leU64", "leU64", "leU64($1, $2)", "leU64($1, $2)"], # leU64
    ["ltU64", "ltU64", "ltU64($1, $2)", "ltU64($1, $2)"], # ltU64
    ["", "", "($1 == $2)", "($1 == $2)"], # EqEnum
    ["", "", "($1 <= $2)", "($1 <= $2)"], # LeEnum
    ["", "", "($1 < $2)", "($1 < $2)"], # LtEnum
    ["", "", "($1 == $2)", "($1 == $2)"], # EqCh
    ["", "", "($1 <= $2)", "($1 <= $2)"], # LeCh
    ["", "", "($1 < $2)", "($1 < $2)"], # LtCh
    ["", "", "($1 == $2)", "($1 == $2)"], # EqB
    ["", "", "($1 <= $2)", "($1 <= $2)"], # LeB
    ["", "", "($1 < $2)", "($1 < $2)"], # LtB
    ["", "", "($1 == $2)", "($1 == $2)"], # EqRef
    ["", "", "($1 == $2)", "($1 == $2)"], # EqUntracedRef
    ["", "", "($1 <= $2)", "($1 <= $2)"], # LePtr
    ["", "", "($1 < $2)", "($1 < $2)"], # LtPtr
    ["", "", "($1 == $2)", "($1 == $2)"], # EqCString
    ["", "", "($1 != $2)", "($1 != $2)"], # Xor
    ["", "", "($1 == $2)", "($1 == $2)"], # EqProc
    ["negInt", "", "negInt($1)", "-($1)"], # UnaryMinusI
    ["negInt64", "", "negInt64($1)", "-($1)"], # UnaryMinusI64
    ["absInt", "", "absInt($1)", "Math.abs($1)"], # AbsI
    ["", "", "not ($1)", "not ($1)"], # Not
    ["", "", "+($1)", "+($1)"], # UnaryPlusI
    ["", "", "~($1)", "~($1)"], # BitnotI
    ["", "", "+($1)", "+($1)"], # UnaryPlusF64
    ["", "", "-($1)", "-($1)"], # UnaryMinusF64
    ["", "", "Math.abs($1)", "Math.abs($1)"], # AbsF64
    ["Ze8ToI", "Ze8ToI", "Ze8ToI($1)", "Ze8ToI($1)"], # mZe8ToI
    ["Ze8ToI64", "Ze8ToI64", "Ze8ToI64($1)", "Ze8ToI64($1)"], # mZe8ToI64
    ["Ze16ToI", "Ze16ToI", "Ze16ToI($1)", "Ze16ToI($1)"], # mZe16ToI
    ["Ze16ToI64", "Ze16ToI64", "Ze16ToI64($1)", "Ze16ToI64($1)"], # mZe16ToI64
    ["Ze32ToI64", "Ze32ToI64", "Ze32ToI64($1)", "Ze32ToI64($1)"], # mZe32ToI64
    ["ZeIToI64", "ZeIToI64", "ZeIToI64($1)", "ZeIToI64($1)"], # mZeIToI64
    ["toU8", "toU8", "toU8($1)", "toU8($1)"], # toU8
    ["toU16", "toU16", "toU16($1)", "toU16($1)"], # toU16
    ["toU32", "toU32", "toU32($1)", "toU32($1)"], # toU32
    ["", "", "$1", "$1"],     # ToFloat
    ["", "", "$1", "$1"],     # ToBiggestFloat
    ["", "", "Math.floor($1)", "Math.floor($1)"], # ToInt
    ["", "", "Math.floor($1)", "Math.floor($1)"], # ToBiggestInt
    ["nimCharToStr", "nimCharToStr", "nimCharToStr($1)", "nimCharToStr($1)"],
    ["nimBoolToStr", "nimBoolToStr", "nimBoolToStr($1)", "nimBoolToStr($1)"], [
      "cstrToNimstr", "cstrToNimstr", "cstrToNimstr(($1)+\"\")",
      "cstrToNimstr(($1)+\"\")"], ["cstrToNimstr", "cstrToNimstr",
                                   "cstrToNimstr(($1)+\"\")",
                                   "cstrToNimstr(($1)+\"\")"], ["cstrToNimstr",
      "cstrToNimstr", "cstrToNimstr(($1)+\"\")", "cstrToNimstr(($1)+\"\")"],
    ["cstrToNimstr", "cstrToNimstr", "cstrToNimstr($1)", "cstrToNimstr($1)"],
    ["", "", "$1", "$1"]]

proc binaryExpr(p: PProc, n: PNode, r: var TCompRes, magic, frmt: string) =
  var x, y: TCompRes
  useMagic(p, magic)
  gen(p, n.sons[1], x)
  gen(p, n.sons[2], y)
  r.res = frmt % [x.rdLoc, y.rdLoc]
  r.kind = resExpr

proc ternaryExpr(p: PProc, n: PNode, r: var TCompRes, magic, frmt: string) =
  var x, y, z: TCompRes
  useMagic(p, magic)
  gen(p, n.sons[1], x)
  gen(p, n.sons[2], y)
  gen(p, n.sons[3], z)
  r.res = frmt % [x.rdLoc, y.rdLoc, z.rdLoc]
  r.kind = resExpr

proc unaryExpr(p: PProc, n: PNode, r: var TCompRes, magic, frmt: string) =
  useMagic(p, magic)
  gen(p, n.sons[1], r)
  r.res = frmt % [r.rdLoc]
  r.kind = resExpr

proc arithAux(p: PProc, n: PNode, r: var TCompRes, op: TMagic, ops: TMagicOps) =
  var
    x, y: TCompRes
  let i = ord(optOverflowCheck notin p.options)
  useMagic(p, ops[op][i])
  if sonsLen(n) > 2:
    gen(p, n.sons[1], x)
    gen(p, n.sons[2], y)
    r.res = ops[op][i + 2] % [x.rdLoc, y.rdLoc]
  else:
    gen(p, n.sons[1], r)
    r.res = ops[op][i + 2] % [r.rdLoc]
  r.kind = resExpr

proc arith(p: PProc, n: PNode, r: var TCompRes, op: TMagic) =
  arithAux(p, n, r, op, jsOps | luaOps)

proc genLineDir(p: PProc, n: PNode) =
  let line = toLinenumber(n.info)
  if optLineDir in p.options:
    addf(p.body, "// line $2 \"$1\"$n" | "-- line $2 \"$1\"$n",
         [rope(toFilename(n.info)), rope(line)])
  if {optStackTrace, optEndb} * p.options == {optStackTrace, optEndb} and
      ((p.prc == nil) or sfPure notin p.prc.flags):
    useMagic(p, "endb")
    addf(p.body, "endb($1);$n", [rope(line)])
  elif ({optLineTrace, optStackTrace} * p.options ==
      {optLineTrace, optStackTrace}) and
      ((p.prc == nil) or not (sfPure in p.prc.flags)):
    addf(p.body, "F.line = $1;$n", [rope(line)])

proc genWhileStmt(p: PProc, n: PNode) =
  var
    cond: TCompRes
  internalAssert isEmptyType(n.typ)
  genLineDir(p, n)
  inc(p.unique)
  var length = len(p.blocks)
  setLen(p.blocks, length + 1)
  p.blocks[length].id = -p.unique
  p.blocks[length].isLoop = true
  let labl = p.unique.rope
  addf(p.body, "L$1: while (true) {$n" | "while true do$n", [labl])
  gen(p, n.sons[0], cond)
  addf(p.body, "if (!$1) break L$2;$n" | "if not $1 then goto ::L$2:: end;$n",
       [cond.res, labl])
  genStmt(p, n.sons[1])
  addf(p.body, "}$n" | "end ::L$#::$n", [labl])
  setLen(p.blocks, length)

proc moveInto(p: PProc, src: var TCompRes, dest: TCompRes) =
  if src.kind != resNone:
    if dest.kind != resNone:
      p.body.addf("$1 = $2;$n", [dest.rdLoc, src.rdLoc])
    else:
      p.body.addf("$1;$n", [src.rdLoc])
    src.kind = resNone
    src.res = nil

proc genTry(p: PProc, n: PNode, r: var TCompRes) =
  # code to generate:
  #
  #  ++excHandler;
  #  try {
  #    stmts;
  #  } catch (EXC) {
  #    var prevJSError = lastJSError; lastJSError = EXC;
  #    --excHandler;
  #    if (e.typ && e.typ == NTI433 || e.typ == NTI2321) {
  #      stmts;
  #    } else if (e.typ && e.typ == NTI32342) {
  #      stmts;
  #    } else {
  #      stmts;
  #    }
  #    lastJSError = prevJSError;
  #  } finally {
  #    stmts;
  #  }
  genLineDir(p, n)
  if not isEmptyType(n.typ):
    r.kind = resVal
    r.res = getTemp(p)
  inc(p.unique)
  var i = 1
  var length = sonsLen(n)
  var catchBranchesExist = length > 1 and n.sons[i].kind == nkExceptBranch
  if catchBranchesExist:
    add(p.body, "++excHandler;" & tnl)
  var safePoint = "Tmp$1" % [rope(p.unique)]
  addf(p.body,
       "" |
       "local $1 = pcall(",
       [safePoint])
  if optStackTrace in p.options: add(p.body, "framePtr = F;" & tnl)
  addf(p.body, "try {$n" | "function()$n", [])
  var a: TCompRes
  gen(p, n.sons[0], a)
  moveInto(p, a, r)
  var generalCatchBranchExists = false
  if p.target == targetJS and catchBranchesExist:
    addf(p.body, "} catch (EXC) {$n var prevJSError = lastJSError;$n" &
        " lastJSError = EXC;$n --excHandler;$n", [])
  elif p.target == targetLua:
    addf(p.body, "end)$n", [])
  while i < length and n.sons[i].kind == nkExceptBranch:
    let blen = sonsLen(n.sons[i])
    if blen == 1:
      # general except section:
      generalCatchBranchExists = true
      if i > 1: addf(p.body, "else {$n" | "else$n", [])
      gen(p, n.sons[i].sons[0], a)
      moveInto(p, a, r)
      if i > 1: addf(p.body, "}$n" | "end$n", [])
    else:
      var orExpr: Rope = nil
      useMagic(p, "isObj")
      for j in countup(0, blen - 2):
        if n.sons[i].sons[j].kind != nkType:
          internalError(n.info, "genTryStmt")
        if orExpr != nil: add(orExpr, "||" | " or ")
        addf(orExpr, "isObj(lastJSError.m_type, $1)",
             [genTypeInfo(p, n.sons[i].sons[j].typ)])
      if i > 1: add(p.body, "else ")
      addf(p.body, "if (lastJSError && ($2)) {$n" | "if $1.exc and ($2) then$n",
        [safePoint, orExpr])
      gen(p, n.sons[i].sons[blen - 1], a)
      moveInto(p, a, r)
      addf(p.body, "}$n" | "end$n", [])
    inc(i)
  if p.target == targetJS:
    if catchBranchesExist:
      if not generalCatchBranchExists:
        useMagic(p, "reraiseException")
        add(p.body, "else {" & tnl & "reraiseException();" & tnl & "}" & tnl)
      add(p.body, "lastJSError = prevJSError;" & tnl)
    add(p.body, "} finally {" & tnl)
  if i < length and n.sons[i].kind == nkFinally:
    genStmt(p, n.sons[i].sons[0])
  if p.target == targetJS:
    add(p.body, "}" & tnl)
  if p.target == targetLua:
    # we need to repeat the finally block for Lua ...
    if i < length and n.sons[i].kind == nkFinally:
      genStmt(p, n.sons[i].sons[0])

proc genRaiseStmt(p: PProc, n: PNode) =
  genLineDir(p, n)
  if n.sons[0].kind != nkEmpty:
    var a: TCompRes
    gen(p, n.sons[0], a)
    let typ = skipTypes(n.sons[0].typ, abstractPtrs)
    useMagic(p, "raiseException")
    addf(p.body, "raiseException($1, $2);$n",
         [a.rdLoc, makeJSString(typ.sym.name.s)])
  else:
    useMagic(p, "reraiseException")
    add(p.body, "reraiseException();" & tnl)

proc genCaseJS(p: PProc, n: PNode, r: var TCompRes) =
  var
    cond, stmt: TCompRes
  genLineDir(p, n)
  gen(p, n.sons[0], cond)
  let stringSwitch = skipTypes(n.sons[0].typ, abstractVar).kind == tyString
  if stringSwitch:
    useMagic(p, "toJSStr")
    addf(p.body, "switch (toJSStr($1)) {$n", [cond.rdLoc])
  else:
    addf(p.body, "switch ($1) {$n", [cond.rdLoc])
  if not isEmptyType(n.typ):
    r.kind = resVal
    r.res = getTemp(p)
  for i in countup(1, sonsLen(n) - 1):
    let it = n.sons[i]
    case it.kind
    of nkOfBranch:
      for j in countup(0, sonsLen(it) - 2):
        let e = it.sons[j]
        if e.kind == nkRange:
          var v = copyNode(e.sons[0])
          while v.intVal <= e.sons[1].intVal:
            gen(p, v, cond)
            addf(p.body, "case $1: ", [cond.rdLoc])
            inc(v.intVal)
        else:
          if stringSwitch:
            case e.kind
            of nkStrLit..nkTripleStrLit: addf(p.body, "case $1: ",
                [makeJSString(e.strVal)])
            else: internalError(e.info, "jsgen.genCaseStmt: 2")
          else:
            gen(p, e, cond)
            addf(p.body, "case $1: ", [cond.rdLoc])
      gen(p, lastSon(it), stmt)
      moveInto(p, stmt, r)
      addf(p.body, "$nbreak;$n", [])
    of nkElse:
      addf(p.body, "default: $n", [])
      gen(p, it.sons[0], stmt)
      moveInto(p, stmt, r)
      addf(p.body, "break;$n", [])
    else: internalError(it.info, "jsgen.genCaseStmt")
  addf(p.body, "}$n", [])

proc genCaseLua(p: PProc, n: PNode, r: var TCompRes) =
  var
    cond, stmt: TCompRes
  genLineDir(p, n)
  gen(p, n.sons[0], cond)
  let stringSwitch = skipTypes(n.sons[0].typ, abstractVar).kind == tyString
  if stringSwitch:
    useMagic(p, "eqStr")
  let tmp = getTemp(p)
  addf(p.body, "$1 = $2;$n", [tmp, cond.rdLoc])
  if not isEmptyType(n.typ):
    r.kind = resVal
    r.res = getTemp(p)
  for i in countup(1, sonsLen(n) - 1):
    let it = n.sons[i]
    case it.kind
    of nkOfBranch:
      if i != 1: addf(p.body, "$nelsif ", [])
      else: addf(p.body, "if ", [])
      for j in countup(0, sonsLen(it) - 2):
        if j != 0: add(p.body, " or ")
        let e = it.sons[j]
        if e.kind == nkRange:
          var ia, ib: TCompRes
          gen(p, e.sons[0], ia)
          gen(p, e.sons[1], ib)
          addf(p.body, "$1 >= $2 and $1 <= $3", [tmp, ia.rdLoc, ib.rdLoc])
        else:
          if stringSwitch:
            case e.kind
            of nkStrLit..nkTripleStrLit: addf(p.body, "eqStr($1, $2)",
                [tmp, makeJSString(e.strVal)])
            else: internalError(e.info, "jsgen.genCaseStmt: 2")
          else:
            gen(p, e, cond)
            addf(p.body, "$1 == $2", [tmp, cond.rdLoc])
      addf(p.body, " then$n", [])
      gen(p, lastSon(it), stmt)
      moveInto(p, stmt, r)
    of nkElse:
      addf(p.body, "else$n", [])
      gen(p, it.sons[0], stmt)
      moveInto(p, stmt, r)
    else: internalError(it.info, "jsgen.genCaseStmt")
  addf(p.body, "$nend$n", [])

proc genBlock(p: PProc, n: PNode, r: var TCompRes) =
  inc(p.unique)
  let idx = len(p.blocks)
  if n.sons[0].kind != nkEmpty:
    # named block?
    if (n.sons[0].kind != nkSym): internalError(n.info, "genBlock")
    var sym = n.sons[0].sym
    sym.loc.k = locOther
    sym.position = idx+1
  setLen(p.blocks, idx + 1)
  p.blocks[idx].id = - p.unique # negative because it isn't used yet
  let labl = p.unique
  addf(p.body, "L$1: do {$n" | "", [labl.rope])
  gen(p, n.sons[1], r)
  addf(p.body, "} while(false);$n" | "$n::L$#::$n", [labl.rope])
  setLen(p.blocks, idx)

proc genBreakStmt(p: PProc, n: PNode) =
  var idx: int
  genLineDir(p, n)
  if n.sons[0].kind != nkEmpty:
    # named break?
    assert(n.sons[0].kind == nkSym)
    let sym = n.sons[0].sym
    assert(sym.loc.k == locOther)
    idx = sym.position-1
  else:
    # an unnamed 'break' can only break a loop after 'transf' pass:
    idx = len(p.blocks) - 1
    while idx >= 0 and not p.blocks[idx].isLoop: dec idx
    if idx < 0 or not p.blocks[idx].isLoop:
      internalError(n.info, "no loop to break")
  p.blocks[idx].id = abs(p.blocks[idx].id) # label is used
  addf(p.body, "break L$1;$n" | "goto ::L$1::;$n", [rope(p.blocks[idx].id)])

proc genAsmOrEmitStmt(p: PProc, n: PNode) =
  genLineDir(p, n)
  for i in countup(0, sonsLen(n) - 1):
    case n.sons[i].kind
    of nkStrLit..nkTripleStrLit: add(p.body, n.sons[i].strVal)
    of nkSym: add(p.body, mangleName(n.sons[i].sym))
    else: internalError(n.sons[i].info, "jsgen: genAsmOrEmitStmt()")

proc genIf(p: PProc, n: PNode, r: var TCompRes) =
  var cond, stmt: TCompRes
  var toClose = 0
  if not isEmptyType(n.typ):
    r.kind = resVal
    r.res = getTemp(p)
  for i in countup(0, sonsLen(n) - 1):
    let it = n.sons[i]
    if sonsLen(it) != 1:
      if i > 0:
        addf(p.body, "else {$n" | "else$n", [])
        inc(toClose)
      gen(p, it.sons[0], cond)
      addf(p.body, "if ($1) {$n" | "if $# then$n", [cond.rdLoc])
      gen(p, it.sons[1], stmt)
    else:
      # else part:
      addf(p.body, "else {$n" | "else$n", [])
      gen(p, it.sons[0], stmt)
    moveInto(p, stmt, r)
    addf(p.body, "}$n" | "end$n", [])
  if p.target == targetJS:
    add(p.body, repeat('}', toClose) & tnl)
  else:
    for i in 1..toClose: addf(p.body, "end$n", [])

proc generateHeader(p: PProc, typ: PType): Rope =
  result = nil
  for i in countup(1, sonsLen(typ.n) - 1):
    assert(typ.n.sons[i].kind == nkSym)
    var param = typ.n.sons[i].sym
    if isCompileTimeOnly(param.typ): continue
    if result != nil: add(result, ", ")
    var name = mangleName(param)
    add(result, name)
    if mapType(param.typ) == etyBaseIndex:
      add(result, ", ")
      add(result, name)
      add(result, "_Idx")

const
  nodeKindsNeedNoCopy = {nkCharLit..nkInt64Lit, nkStrLit..nkTripleStrLit,
    nkFloatLit..nkFloat64Lit, nkCurly, nkPar, nkObjConstr, nkStringToCString,
    nkCStringToString, nkCall, nkPrefix, nkPostfix, nkInfix,
    nkCommand, nkHiddenCallConv, nkCallStrLit}

proc needsNoCopy(y: PNode): bool =
  result = (y.kind in nodeKindsNeedNoCopy) or
      (skipTypes(y.typ, abstractInst).kind in {tyRef, tyPtr, tyVar})

proc genAsgnAux(p: PProc, x, y: PNode, noCopyNeeded: bool) =
  var a, b: TCompRes
  gen(p, x, a)

  let xtyp = mapType(x.typ)

  if x.kind == nkHiddenDeref and x.sons[0].kind == nkCall and xtyp != etyObject:
    gen(p, x.sons[0], a)
    let tmp = p.getTemp(false)
    addf(p.body, "var $1 = $2;$n", [tmp, a.rdLoc])
    a.res = "$1[0][$1[1]]" % [tmp]
  else:
    gen(p, x, a)

  gen(p, y, b)

  case xtyp
  of etyObject:
    if (needsNoCopy(y) and needsNoCopy(x)) or noCopyNeeded:
      addf(p.body, "$1 = $2;$n", [a.rdLoc, b.rdLoc])
    else:
      useMagic(p, "nimCopy")
      addf(p.body, "nimCopy($1, $2, $3);$n",
           [a.res, b.res, genTypeInfo(p, y.typ)])
  of etyBaseIndex:
    if a.typ != etyBaseIndex or b.typ != etyBaseIndex:
      if y.kind == nkCall:
        let tmp = p.getTemp(false)
        addf(p.body, "var $1 = $4; $2 = $1[0]; $3 = $1[1];$n", [tmp, a.address, a.res, b.rdLoc])
      else:
        internalError(x.info, "genAsgn")
    else:
      addf(p.body, "$1 = $2; $3 = $4;$n", [a.address, b.address, a.res, b.res])
  else:
    addf(p.body, "$1 = $2;$n", [a.res, b.res])

proc genAsgn(p: PProc, n: PNode) =
  genLineDir(p, n)
  genAsgnAux(p, n.sons[0], n.sons[1], noCopyNeeded=false)

proc genFastAsgn(p: PProc, n: PNode) =
  genLineDir(p, n)
  genAsgnAux(p, n.sons[0], n.sons[1], noCopyNeeded=true)

proc genSwap(p: PProc, n: PNode) =
  var a, b: TCompRes
  gen(p, n.sons[1], a)
  gen(p, n.sons[2], b)
  var tmp = p.getTemp(false)
  if mapType(skipTypes(n.sons[1].typ, abstractVar)) == etyBaseIndex:
    let tmp2 = p.getTemp(false)
    if a.typ != etyBaseIndex or b.typ != etyBaseIndex:
      internalError(n.info, "genSwap")
    addf(p.body, "var $1 = $2; $2 = $3; $3 = $1;$n" |
                 "local $1 = $2; $2 = $3; $3 = $1;$n", [
                 tmp, a.address, b.address])
    tmp = tmp2
  addf(p.body, "var $1 = $2; $2 = $3; $3 = $1;" |
               "local $1 = $2; $2 = $3; $3 = $1;", [tmp, a.res, b.res])

proc getFieldPosition(f: PNode): int =
  case f.kind
  of nkIntLit..nkUInt64Lit: result = int(f.intVal)
  of nkSym: result = f.sym.position
  else: internalError(f.info, "genFieldPosition")

proc genFieldAddr(p: PProc, n: PNode, r: var TCompRes) =
  var a: TCompRes
  r.typ = etyBaseIndex
  let b = if n.kind == nkHiddenAddr: n.sons[0] else: n
  gen(p, b.sons[0], a)
  if skipTypes(b.sons[0].typ, abstractVarRange).kind == tyTuple:
    r.res = makeJSString("Field" & $getFieldPosition(b.sons[1]))
  else:
    if b.sons[1].kind != nkSym: internalError(b.sons[1].info, "genFieldAddr")
    var f = b.sons[1].sym
    if f.loc.r == nil: f.loc.r = mangleName(f)
    r.res = makeJSString($f.loc.r)
  internalAssert a.typ != etyBaseIndex
  r.address = a.res
  r.kind = resExpr

proc genFieldAccess(p: PProc, n: PNode, r: var TCompRes) =
  r.typ = etyNone
  gen(p, n.sons[0], r)
  if skipTypes(n.sons[0].typ, abstractVarRange).kind == tyTuple:
    r.res = "$1.Field$2" % [r.res, getFieldPosition(n.sons[1]).rope]
  else:
    if n.sons[1].kind != nkSym: internalError(n.sons[1].info, "genFieldAccess")
    var f = n.sons[1].sym
    if f.loc.r == nil: f.loc.r = mangleName(f)
    r.res = "$1.$2" % [r.res, f.loc.r]
  r.kind = resExpr

proc genCheckedFieldAddr(p: PProc, n: PNode, r: var TCompRes) =
  let m = if n.kind == nkHiddenAddr: n.sons[0] else: n
  internalAssert m.kind == nkCheckedFieldExpr
  genFieldAddr(p, m.sons[0], r) # XXX

proc genCheckedFieldAccess(p: PProc, n: PNode, r: var TCompRes) =
  genFieldAccess(p, n.sons[0], r) # XXX

proc genArrayAddr(p: PProc, n: PNode, r: var TCompRes) =
  var
    a, b: TCompRes
    first: BiggestInt
  r.typ = etyBaseIndex
  let m = if n.kind == nkHiddenAddr: n.sons[0] else: n
  gen(p, m.sons[0], a)
  gen(p, m.sons[1], b)
  internalAssert a.typ != etyBaseIndex and b.typ != etyBaseIndex
  r.address = a.res
  var typ = skipTypes(m.sons[0].typ, abstractPtrs)
  if typ.kind in {tyArray, tyArrayConstr}: first = firstOrd(typ.sons[0])
  else: first = 0
  if optBoundsCheck in p.options and not isConstExpr(m.sons[1]):
    useMagic(p, "chckIndx")
    r.res = "chckIndx($1, $2, $3.length)-$2" % [b.res, rope(first), a.res]
  elif first != 0:
    r.res = "($1)-$2" % [b.res, rope(first)]
  else:
    r.res = b.res
  r.kind = resExpr

proc genArrayAccess(p: PProc, n: PNode, r: var TCompRes) =
  var ty = skipTypes(n.sons[0].typ, abstractVarRange)
  if ty.kind in {tyRef, tyPtr}: ty = skipTypes(ty.lastSon, abstractVarRange)
  case ty.kind
  of tyArray, tyArrayConstr, tyOpenArray, tySequence, tyString, tyCString,
     tyVarargs:
    genArrayAddr(p, n, r)
  of tyTuple:
    genFieldAddr(p, n, r)
  else: internalError(n.info, "expr(nkBracketExpr, " & $ty.kind & ')')
  r.typ = etyNone
  if r.res == nil: internalError(n.info, "genArrayAccess")
  r.res = "$1[$2]" % [r.address, r.res]
  r.address = nil
  r.kind = resExpr

proc isIndirect(v: PSym): bool =
  result = {sfAddrTaken, sfGlobal} * v.flags != {} and
    #(mapType(v.typ) != etyObject) and
    {sfImportc, sfVolatile, sfExportc} * v.flags == {} and
    v.kind notin {skProc, skConverter, skMethod, skIterator, skClosureIterator,
                  skConst, skTemp, skLet}

proc genAddr(p: PProc, n: PNode, r: var TCompRes) =
  case n.sons[0].kind
  of nkSym:
    let s = n.sons[0].sym
    if s.loc.r == nil: internalError(n.info, "genAddr: 3")
    case s.kind
    of skVar, skLet, skResult:
      r.kind = resExpr
      let jsType = mapType(n.typ)
      if jsType == etyObject:
        # make addr() a no-op:
        r.typ = etyNone
        if isIndirect(s):
          r.res = s.loc.r & "[0]"
        else:
          r.res = s.loc.r
        r.address = nil
      elif {sfGlobal, sfAddrTaken} * s.flags != {} or jsType == etyBaseIndex:
        # for ease of code generation, we do not distinguish between
        # sfAddrTaken and sfGlobal.
        r.typ = etyBaseIndex
        r.address = s.loc.r
        r.res = rope("0")
      else:
        # 'var openArray' for instance produces an 'addr' but this is harmless:
        gen(p, n.sons[0], r)
        #internalError(n.info, "genAddr: 4 " & renderTree(n))
    else: internalError(n.info, "genAddr: 2")
  of nkCheckedFieldExpr:
    genCheckedFieldAddr(p, n, r)
  of nkDotExpr:
    if mapType(n.typ) == etyBaseIndex:
      genFieldAddr(p, n.sons[0], r)
    else:
      genFieldAccess(p, n.sons[0], r)
  of nkBracketExpr:
    var ty = skipTypes(n.sons[0].typ, abstractVarRange)
    if ty.kind in MappedToObject:
      gen(p, n.sons[0], r)
    else:
      let kindOfIndexedExpr = skipTypes(n.sons[0].sons[0].typ, abstractVarRange).kind
      case kindOfIndexedExpr
      of tyArray, tyArrayConstr, tyOpenArray, tySequence, tyString, tyCString,
          tyVarargs:
        genArrayAddr(p, n.sons[0], r)
      of tyTuple:
        genFieldAddr(p, n.sons[0], r)
      else: internalError(n.sons[0].info, "expr(nkBracketExpr, " & $kindOfIndexedExpr & ')')
  of nkObjDownConv:
    gen(p, n.sons[0], r)
  else: internalError(n.sons[0].info, "genAddr: " & $n.sons[0].kind)

proc genProcForSymIfNeeded(p: PProc, s: PSym) =
  if not p.g.generatedSyms.containsOrIncl(s.id):
    let newp = genProc(p, s)
    var owner = p
    while owner != nil and owner.prc != s.owner:
      owner = owner.up
    if owner != nil: add(owner.locals, newp)
    else: add(p.g.code, newp)

proc genSym(p: PProc, n: PNode, r: var TCompRes) =
  var s = n.sym
  case s.kind
  of skVar, skLet, skParam, skTemp, skResult:
    if s.loc.r == nil:
      internalError(n.info, "symbol has no generated name: " & s.name.s)
    let k = mapType(s.typ)
    if k == etyBaseIndex:
      r.typ = etyBaseIndex
      if {sfAddrTaken, sfGlobal} * s.flags != {}:
        r.address = "$1[0]" % [s.loc.r]
        r.res = "$1[1]" % [s.loc.r]
      else:
        r.address = s.loc.r
        r.res = s.loc.r & "_Idx"
    elif isIndirect(s):
      r.res = "$1[0]" % [s.loc.r]
    else:
      r.res = s.loc.r
  of skConst:
    genConstant(p, s)
    if s.loc.r == nil:
      internalError(n.info, "symbol has no generated name: " & s.name.s)
    r.res = s.loc.r
  of skProc, skConverter, skMethod:
    discard mangleName(s)
    r.res = s.loc.r
    if lfNoDecl in s.loc.flags or s.magic != mNone or
       {sfImportc, sfInfixCall} * s.flags != {}:
      discard
    elif s.kind == skMethod and s.getBody.kind == nkEmpty:
      # we cannot produce code for the dispatcher yet:
      discard
    elif sfForward in s.flags:
      p.g.forwarded.add(s)
    else:
      genProcForSymIfNeeded(p, s)
  else:
    if s.loc.r == nil:
      internalError(n.info, "symbol has no generated name: " & s.name.s)
    r.res = s.loc.r
  r.kind = resVal

proc genDeref(p: PProc, n: PNode, r: var TCompRes) =
  if mapType(n.sons[0].typ) == etyObject:
    gen(p, n.sons[0], r)
  else:
    var a: TCompRes
    gen(p, n.sons[0], a)
    if a.typ == etyBaseIndex:
      r.res = "$1[$2]" % [a.address, a.res]
    elif n.sons[0].kind == nkCall:
      let tmp = p.getTemp
      r.res = "($1 = $2, $1[0][$1[1]])" % [tmp, a.res]
    else:
      internalError(n.info, "genDeref")

proc genArgNoParam(p: PProc, n: PNode, r: var TCompRes) =
  var a: TCompRes
  gen(p, n, a)
  if a.typ == etyBaseIndex:
    add(r.res, a.address)
    add(r.res, ", ")
    add(r.res, a.res)
  else:
    add(r.res, a.res)

proc genArg(p: PProc, n: PNode, param: PSym, r: var TCompRes) =
  var a: TCompRes
  gen(p, n, a)
  if skipTypes(param.typ, abstractVar).kind in {tyOpenArray, tyVarargs} and
      a.typ == etyBaseIndex:
    add(r.res, "$1[$2]" % [a.address, a.res])
  elif a.typ == etyBaseIndex:
    add(r.res, a.address)
    add(r.res, ", ")
    add(r.res, a.res)
  else:
    add(r.res, a.res)


proc genArgs(p: PProc, n: PNode, r: var TCompRes) =
  add(r.res, "(")
  var hasArgs = false

  var typ = skipTypes(n.sons[0].typ, abstractInst)
  assert(typ.kind == tyProc)
  assert(sonsLen(typ) == sonsLen(typ.n))

  for i in countup(1, sonsLen(n) - 1):
    let it = n.sons[i]
    var paramType : PNode = nil
    if i < sonsLen(typ):
      assert(typ.n.sons[i].kind == nkSym)
      paramType = typ.n.sons[i]
      if paramType.typ.isCompileTimeOnly: continue

    if hasArgs: add(r.res, ", ")
    if paramType.isNil:
      genArgNoParam(p, it, r)
    else:
      genArg(p, it, paramType.sym, r)
    hasArgs = true
  add(r.res, ")")
  r.kind = resExpr

proc genCall(p: PProc, n: PNode, r: var TCompRes) =
  gen(p, n.sons[0], r)
  genArgs(p, n, r)

proc genInfixCall(p: PProc, n: PNode, r: var TCompRes) =
  gen(p, n.sons[1], r)
  if r.typ == etyBaseIndex:
    if r.address == nil:
      globalError(n.info, "cannot invoke with infix syntax")
    r.res = "$1[$2]" % [r.address, r.res]
    r.address = nil
    r.typ = etyNone
  add(r.res, ".")
  var op: TCompRes
  gen(p, n.sons[0], op)
  add(r.res, op.res)

  add(r.res, "(")
  for i in countup(2, sonsLen(n) - 1):
    if i > 2: add(r.res, ", ")
    genArgNoParam(p, n.sons[i], r)
  add(r.res, ")")
  r.kind = resExpr

proc genEcho(p: PProc, n: PNode, r: var TCompRes) =
  useMagic(p, "toJSStr") # Used in rawEcho
  useMagic(p, "rawEcho")
  add(r.res, "rawEcho(")
  let n = n[1].skipConv
  internalAssert n.kind == nkBracket
  for i in countup(0, sonsLen(n) - 1):
    let it = n.sons[i]
    if it.typ.isCompileTimeOnly: continue
    if i > 0: add(r.res, ", ")
    genArgNoParam(p, it, r)
  add(r.res, ")")
  r.kind = resExpr

proc putToSeq(s: string, indirect: bool): Rope =
  result = rope(s)
  if indirect: result = "[$1]" % [result]

proc createVar(p: PProc, typ: PType, indirect: bool): Rope
proc createRecordVarAux(p: PProc, rec: PNode, excludedFieldIDs: IntSet, output: var Rope) =
  case rec.kind
  of nkRecList:
    for i in countup(0, sonsLen(rec) - 1):
      createRecordVarAux(p, rec.sons[i], excludedFieldIDs, output)
  of nkRecCase:
    createRecordVarAux(p, rec.sons[0], excludedFieldIDs, output)
    for i in countup(1, sonsLen(rec) - 1):
      createRecordVarAux(p, lastSon(rec.sons[i]), excludedFieldIDs, output)
  of nkSym:
    if rec.sym.id notin excludedFieldIDs:
      if output.len > 0: output.add(", ")
      output.add(mangleName(rec.sym))
      output.add(": ")
      output.add(createVar(p, rec.sym.typ, false))
  else: internalError(rec.info, "createRecordVarAux")

proc createObjInitList(p: PProc, typ: PType, excludedFieldIDs: IntSet, output: var Rope) =
  var t = typ
  if tfFinal notin t.flags or t.sons[0] != nil:
    if output.len > 0: output.add(", ")
    addf(output, "m_type: $1" | "m_type = $#", [genTypeInfo(p, t)])
  while t != nil:
    createRecordVarAux(p, t.n, excludedFieldIDs, output)
    t = t.sons[0]

proc createVar(p: PProc, typ: PType, indirect: bool): Rope =
  var t = skipTypes(typ, abstractInst)
  case t.kind
  of tyInt..tyInt64, tyUInt..tyUInt64, tyEnum, tyChar:
    result = putToSeq("0", indirect)
  of tyFloat..tyFloat128:
    result = putToSeq("0.0", indirect)
  of tyRange, tyGenericInst:
    result = createVar(p, lastSon(typ), indirect)
  of tySet:
    result = putToSeq("{}", indirect)
  of tyBool:
    result = putToSeq("false", indirect)
  of tyArray, tyArrayConstr:
    var length = int(lengthOrd(t))
    var e = elemType(t)
    if length > 32:
      useMagic(p, "arrayConstr")
      # XXX: arrayConstr depends on nimCopy. This line shouldn't be necessary.
      useMagic(p, "nimCopy")
      result = "arrayConstr($1, $2, $3)" % [rope(length),
          createVar(p, e, false), genTypeInfo(p, e)]
    else:
      result = rope("[")
      var i = 0
      while i < length:
        if i > 0: add(result, ", ")
        add(result, createVar(p, e, false))
        inc(i)
      add(result, "]")
    if indirect: result = "[$1]" % [result]
  of tyTuple:
    result = rope("{")
    for i in 0.. <t.sonsLen:
      if i > 0: add(result, ", ")
      addf(result, "Field$1: $2" | "Field$# = $#", [i.rope,
           createVar(p, t.sons[i], false)])
    add(result, "}")
    if indirect: result = "[$1]" % [result]
  of tyObject:
    var initList : Rope
    createObjInitList(p, t, initIntSet(), initList)
    result = "{$1}" % [initList]
    if indirect: result = "[$1]" % [result]
  of tyVar, tyPtr, tyRef:
    if mapType(t) == etyBaseIndex:
      result = putToSeq("[null, 0]" | "{nil, 0}", indirect)
    else:
      result = putToSeq("null" | "nil", indirect)
  of tySequence, tyString, tyCString, tyPointer, tyProc:
    result = putToSeq("null" | "nil", indirect)
  else:
    internalError("createVar: " & $t.kind)
    result = nil

proc genVarInit(p: PProc, v: PSym, n: PNode) =
  var
    a: TCompRes
    s: Rope
  if n.kind == nkEmpty:
    addf(p.body, "var $1 = $2;$n" | "local $1 = $2;$n",
         [mangleName(v), createVar(p, v.typ, isIndirect(v))])
  else:
    discard mangleName(v)
    gen(p, n, a)
    case mapType(v.typ)
    of etyObject:
      if needsNoCopy(n):
        s = a.res
      else:
        useMagic(p, "nimCopy")
        s = "nimCopy(null, $1, $2)" % [a.res, genTypeInfo(p, n.typ)]
    of etyBaseIndex:
      if (a.typ != etyBaseIndex): internalError(n.info, "genVarInit")
      if {sfAddrTaken, sfGlobal} * v.flags != {}:
        addf(p.body, "var $1 = [$2, $3];$n" | "local $1 = {$2, $3};$n",
            [v.loc.r, a.address, a.res])
      else:
        addf(p.body, "var $1 = $2; var $1_Idx = $3;$n" |
                     "local $1 = $2; local $1_Idx = $3;$n", [
             v.loc.r, a.address, a.res])
      return
    else:
      s = a.res
    if isIndirect(v):
      addf(p.body, "var $1 = /**/[$2];$n" | "local $1 = {$2};$n", [v.loc.r, s])
    else:
      addf(p.body, "var $1 = $2;$n" | "local $1 = $2;$n", [v.loc.r, s])

proc genVarStmt(p: PProc, n: PNode) =
  for i in countup(0, sonsLen(n) - 1):
    var a = n.sons[i]
    if a.kind != nkCommentStmt:
      if a.kind == nkVarTuple:
        let unpacked = lowerTupleUnpacking(a, p.prc)
        genStmt(p, unpacked)
      else:
        assert(a.kind == nkIdentDefs)
        assert(a.sons[0].kind == nkSym)
        var v = a.sons[0].sym
        if lfNoDecl notin v.loc.flags:
          genLineDir(p, a)
          genVarInit(p, v, a.sons[2])

proc genConstant(p: PProc, c: PSym) =
  if lfNoDecl notin c.loc.flags and not p.g.generatedSyms.containsOrIncl(c.id):
    let oldBody = p.body
    p.body = nil
    #genLineDir(p, c.ast)
    genVarInit(p, c, c.ast)
    add(p.g.code, p.body)
    p.body = oldBody

proc genNew(p: PProc, n: PNode) =
  var a: TCompRes
  gen(p, n.sons[1], a)
  var t = skipTypes(n.sons[1].typ, abstractVar).sons[0]
  addf(p.body, "$1 = $2;$n", [a.res, createVar(p, t, false)])

proc genNewSeq(p: PProc, n: PNode) =
  var x, y: TCompRes
  gen(p, n.sons[1], x)
  gen(p, n.sons[2], y)
  let t = skipTypes(n.sons[1].typ, abstractVar).sons[0]
  addf(p.body, "$1 = new Array($2); for (var i=0;i<$2;++i) {$1[i]=$3;}", [
    x.rdLoc, y.rdLoc, createVar(p, t, false)])

proc genOrd(p: PProc, n: PNode, r: var TCompRes) =
  case skipTypes(n.sons[1].typ, abstractVar).kind
  of tyEnum, tyInt..tyInt64, tyChar: gen(p, n.sons[1], r)
  of tyBool: unaryExpr(p, n, r, "", "($1 ? 1:0)" | "toBool($#)")
  else: internalError(n.info, "genOrd")

proc genConStrStr(p: PProc, n: PNode, r: var TCompRes) =
  var a: TCompRes

  gen(p, n.sons[1], a)
  r.kind = resExpr
  if skipTypes(n.sons[1].typ, abstractVarRange).kind == tyChar:
    r.res.add("[$1].concat(" % [a.res])
  else:
    r.res.add("($1.slice(0,-1)).concat(" % [a.res])

  for i in countup(2, sonsLen(n) - 2):
    gen(p, n.sons[i], a)
    if skipTypes(n.sons[i].typ, abstractVarRange).kind == tyChar:
      r.res.add("[$1]," % [a.res])
    else:
      r.res.add("$1.slice(0,-1)," % [a.res])

  gen(p, n.sons[sonsLen(n) - 1], a)
  if skipTypes(n.sons[sonsLen(n) - 1].typ, abstractVarRange).kind == tyChar:
    r.res.add("[$1, 0])" % [a.res])
  else:
    r.res.add("$1)" % [a.res])

proc genRepr(p: PProc, n: PNode, r: var TCompRes) =
  var t = skipTypes(n.sons[1].typ, abstractVarRange)
  case t.kind
  of tyInt..tyUInt64:
    unaryExpr(p, n, r, "", "(\"\"+ ($1))")
  of tyEnum, tyOrdinal:
    gen(p, n.sons[1], r)
    useMagic(p, "cstrToNimstr")
    r.kind = resExpr
    r.res = "cstrToNimstr($1.node.sons[$2].name)" % [genTypeInfo(p, t), r.res]
  else:
    # XXX:
    internalError(n.info, "genRepr: Not implemented")

proc genOf(p: PProc, n: PNode, r: var TCompRes) =
  var x: TCompRes
  let t = skipTypes(n.sons[2].typ, abstractVarRange+{tyRef, tyPtr, tyTypeDesc})
  gen(p, n.sons[1], x)
  if tfFinal in t.flags:
    r.res = "($1.m_type == $2)" % [x.res, genTypeInfo(p, t)]
  else:
    useMagic(p, "isObj")
    r.res = "isObj($1.m_type, $2)" % [x.res, genTypeInfo(p, t)]
  r.kind = resExpr

proc genReset(p: PProc, n: PNode) =
  var x: TCompRes
  useMagic(p, "genericReset")
  gen(p, n.sons[1], x)
  addf(p.body, "$1 = genericReset($1, $2);$n", [x.res,
                genTypeInfo(p, n.sons[1].typ)])

proc genMagic(p: PProc, n: PNode, r: var TCompRes) =
  var
    a: TCompRes
    line, filen: Rope
  var op = n.sons[0].sym.magic
  case op
  of mOr: genOr(p, n.sons[1], n.sons[2], r)
  of mAnd: genAnd(p, n.sons[1], n.sons[2], r)
  of mAddI..mStrToStr: arith(p, n, r, op)
  of mRepr: genRepr(p, n, r)
  of mSwap: genSwap(p, n)
  of mUnaryLt:
    # XXX: range checking?
    if not (optOverflowCheck in p.options): unaryExpr(p, n, r, "", "$1 - 1")
    else: unaryExpr(p, n, r, "subInt", "subInt($1, 1)")
  of mAppendStrCh: binaryExpr(p, n, r, "addChar",
        "if ($1 != null) { addChar($1, $2); } else { $1 = [$2, 0]; }")
  of mAppendStrStr:
    if skipTypes(n.sons[1].typ, abstractVarRange).kind == tyCString:
        binaryExpr(p, n, r, "", "if ($1 != null) { $1 += $2; } else { $1 = $2; }")
    else:
      binaryExpr(p, n, r, "",
        "if ($1 != null) { $1 = ($1.slice(0, -1)).concat($2); } else { $1 = $2;}")
    # XXX: make a copy of $2, because of Javascript's sucking semantics
  of mAppendSeqElem: binaryExpr(p, n, r, "",
        "if ($1 != null) { $1.push($2); } else { $1 = [$2]; }")
  of mConStrStr: genConStrStr(p, n, r)
  of mEqStr: binaryExpr(p, n, r, "eqStrings", "eqStrings($1, $2)")
  of mLeStr: binaryExpr(p, n, r, "cmpStrings", "(cmpStrings($1, $2) <= 0)")
  of mLtStr: binaryExpr(p, n, r, "cmpStrings", "(cmpStrings($1, $2) < 0)")
  of mIsNil: unaryExpr(p, n, r, "", "$1 == null")
  of mEnumToStr: genRepr(p, n, r)
  of mNew, mNewFinalize: genNew(p, n)
  of mSizeOf: r.res = rope(getSize(n.sons[1].typ))
  of mChr, mArrToSeq: gen(p, n.sons[1], r)      # nothing to do
  of mOrd: genOrd(p, n, r)
  of mLengthStr: unaryExpr(p, n, r, "", "($1 != null ? $1.length-1 : 0)")
  of mXLenStr: unaryExpr(p, n, r, "", "$1.length-1")
  of mLengthSeq, mLengthOpenArray, mLengthArray:
    unaryExpr(p, n, r, "", "($1 != null ? $1.length : 0)")
  of mXLenSeq:
    unaryExpr(p, n, r, "", "$1.length")
  of mHigh:
    if skipTypes(n.sons[1].typ, abstractVar).kind == tyString:
      unaryExpr(p, n, r, "", "($1 != null ? ($1.length-2) : -1)")
    else:
      unaryExpr(p, n, r, "", "($1 != null ? ($1.length-1) : -1)")
  of mInc:
    if optOverflowCheck notin p.options: binaryExpr(p, n, r, "", "$1 += $2")
    else: binaryExpr(p, n, r, "addInt", "$1 = addInt($1, $2)")
  of ast.mDec:
    if optOverflowCheck notin p.options: binaryExpr(p, n, r, "", "$1 -= $2")
    else: binaryExpr(p, n, r, "subInt", "$1 = subInt($1, $2)")
  of mSetLengthStr: binaryExpr(p, n, r, "", "$1.length = $2+1; $1[$1.length-1] = 0")
  of mSetLengthSeq: binaryExpr(p, n, r, "", "$1.length = $2")
  of mCard: unaryExpr(p, n, r, "SetCard", "SetCard($1)")
  of mLtSet: binaryExpr(p, n, r, "SetLt", "SetLt($1, $2)")
  of mLeSet: binaryExpr(p, n, r, "SetLe", "SetLe($1, $2)")
  of mEqSet: binaryExpr(p, n, r, "SetEq", "SetEq($1, $2)")
  of mMulSet: binaryExpr(p, n, r, "SetMul", "SetMul($1, $2)")
  of mPlusSet: binaryExpr(p, n, r, "SetPlus", "SetPlus($1, $2)")
  of mMinusSet: binaryExpr(p, n, r, "SetMinus", "SetMinus($1, $2)")
  of mIncl: binaryExpr(p, n, r, "", "$1[$2] = true")
  of mExcl: binaryExpr(p, n, r, "", "delete $1[$2]")
  of mInSet: binaryExpr(p, n, r, "", "($1[$2] != undefined)")
  of mNewSeq: genNewSeq(p, n)
  of mOf: genOf(p, n, r)
  of mReset: genReset(p, n)
  of mEcho: genEcho(p, n, r)
  of mNLen..mNError, mSlurp, mStaticExec:
    localError(n.info, errXMustBeCompileTime, n.sons[0].sym.name.s)
  of mCopyStr: binaryExpr(p, n, r, "", "($1.slice($2))")
  of mCopyStrLast: ternaryExpr(p, n, r, "", "($1.slice($2, ($3)+1).concat(0))")
  of mNewString: unaryExpr(p, n, r, "mnewString", "mnewString($1)")
  of mNewStringOfCap: unaryExpr(p, n, r, "mnewString", "mnewString(0)")
  of mDotDot:
    genProcForSymIfNeeded(p, n.sons[0].sym)
    genCall(p, n, r)
  of mParseBiggestFloat:
    useMagic(p, "nimParseBiggestFloat")
    genCall(p, n, r)
  else:
    genCall(p, n, r)
    #else internalError(e.info, 'genMagic: ' + magicToStr[op]);

proc genSetConstr(p: PProc, n: PNode, r: var TCompRes) =
  var
    a, b: TCompRes
  useMagic(p, "SetConstr")
  r.res = rope("SetConstr(")
  r.kind = resExpr
  for i in countup(0, sonsLen(n) - 1):
    if i > 0: add(r.res, ", ")
    var it = n.sons[i]
    if it.kind == nkRange:
      gen(p, it.sons[0], a)
      gen(p, it.sons[1], b)
      addf(r.res, "[$1, $2]", [a.res, b.res])
    else:
      gen(p, it, a)
      add(r.res, a.res)
  add(r.res, ")")

proc genArrayConstr(p: PProc, n: PNode, r: var TCompRes) =
  var a: TCompRes
  r.res = rope("[")
  r.kind = resExpr
  for i in countup(0, sonsLen(n) - 1):
    if i > 0: add(r.res, ", ")
    gen(p, n.sons[i], a)
    add(r.res, a.res)
  add(r.res, "]")

proc genTupleConstr(p: PProc, n: PNode, r: var TCompRes) =
  var a: TCompRes
  r.res = rope("{")
  r.kind = resExpr
  for i in countup(0, sonsLen(n) - 1):
    if i > 0: add(r.res, ", ")
    var it = n.sons[i]
    if it.kind == nkExprColonExpr: it = it.sons[1]
    gen(p, it, a)
    addf(r.res, "Field$#: $#" | "Field$# = $#", [i.rope, a.res])
  r.res.add("}")

proc genObjConstr(p: PProc, n: PNode, r: var TCompRes) =
  var a: TCompRes
  r.kind = resExpr
  var initList : Rope
  var fieldIDs = initIntSet()
  for i in countup(1, sonsLen(n) - 1):
    if i > 1: add(initList, ", ")
    var it = n.sons[i]
    internalAssert it.kind == nkExprColonExpr
    gen(p, it.sons[1], a)
    var f = it.sons[0].sym
    if f.loc.r == nil: f.loc.r = mangleName(f)
    fieldIDs.incl(f.id)
    addf(initList, "$#: $#" | "$# = $#" , [f.loc.r, a.res])
  let t = skipTypes(n.typ, abstractInst + skipPtrs)
  createObjInitList(p, t, fieldIDs, initList)
  r.res = "{$1}" % [initList]

proc genConv(p: PProc, n: PNode, r: var TCompRes) =
  var dest = skipTypes(n.typ, abstractVarRange)
  var src = skipTypes(n.sons[1].typ, abstractVarRange)
  gen(p, n.sons[1], r)
  if dest.kind == src.kind:
    # no-op conversion
    return
  case dest.kind:
  of tyBool:
    r.res = ("(($1)? 1:0)" | "toBool($#)") % [r.res]
    r.kind = resExpr
  of tyInt:
    r.res = "($1|0)" % [r.res]
  else:
    # TODO: What types must we handle here?
    discard

proc upConv(p: PProc, n: PNode, r: var TCompRes) =
  gen(p, n.sons[0], r)        # XXX

proc genRangeChck(p: PProc, n: PNode, r: var TCompRes, magic: string) =
  var a, b: TCompRes
  gen(p, n.sons[0], r)
  if optRangeCheck in p.options:
    gen(p, n.sons[1], a)
    gen(p, n.sons[2], b)
    useMagic(p, "chckRange")
    r.res = "chckRange($1, $2, $3)" % [r.res, a.res, b.res]
    r.kind = resExpr

proc convStrToCStr(p: PProc, n: PNode, r: var TCompRes) =
  # we do an optimization here as this is likely to slow down
  # much of the code otherwise:
  if n.sons[0].kind == nkCStringToString:
    gen(p, n.sons[0].sons[0], r)
  else:
    gen(p, n.sons[0], r)
    if r.res == nil: internalError(n.info, "convStrToCStr")
    useMagic(p, "toJSStr")
    r.res = "toJSStr($1)" % [r.res]
    r.kind = resExpr

proc convCStrToStr(p: PProc, n: PNode, r: var TCompRes) =
  # we do an optimization here as this is likely to slow down
  # much of the code otherwise:
  if n.sons[0].kind == nkStringToCString:
    gen(p, n.sons[0].sons[0], r)
  else:
    gen(p, n.sons[0], r)
    if r.res == nil: internalError(n.info, "convCStrToStr")
    useMagic(p, "cstrToNimstr")
    r.res = "cstrToNimstr($1)" % [r.res]
    r.kind = resExpr

proc genReturnStmt(p: PProc, n: PNode) =
  if p.procDef == nil: internalError(n.info, "genReturnStmt")
  p.beforeRetNeeded = true
  if (n.sons[0].kind != nkEmpty):
    genStmt(p, n.sons[0])
  else:
    genLineDir(p, n)
  addf(p.body, "break BeforeRet;$n" | "goto ::BeforeRet::;$n", [])

proc genProcBody(p: PProc, prc: PSym): Rope =
  if optStackTrace in prc.options:
    result = (("var F={procname:$1,prev:framePtr,filename:$2,line:0};$n" |
               "local F={procname=$#,prev=framePtr,filename=$#,line=0};$n") &
              "framePtr = F;$n") % [
              makeJSString(prc.owner.name.s & '.' & prc.name.s),
              makeJSString(toFilename(prc.info))]
  else:
    result = nil
  if p.beforeRetNeeded:
    addf(result, "BeforeRet: do {$n$1} while (false); $n" |
                 "$#;::BeforeRet::$n", [p.body])
  else:
    add(result, p.body)
  if prc.typ.callConv == ccSysCall and p.target == targetJS:
    result = ("try {$n$1} catch (e) {$n" &
      " alert(\"Unhandled exception:\\n\" + e.message + \"\\n\"$n}") % [result]
  if optStackTrace in prc.options:
    add(result, "framePtr = framePtr.prev;" & tnl)

proc genProc(oldProc: PProc, prc: PSym): Rope =
  var
    resultSym: PSym
    name, returnStmt, resultAsgn, header: Rope
    a: TCompRes
  #if gVerbosity >= 3:
  #  echo "BEGIN generating code for: " & prc.name.s
  var p = newProc(oldProc.g, oldProc.module, prc.ast, prc.options)
  p.target = oldProc.target
  p.up = oldProc
  returnStmt = nil
  resultAsgn = nil
  name = mangleName(prc)
  header = generateHeader(p, prc.typ)
  if prc.typ.sons[0] != nil and sfPure notin prc.flags:
    resultSym = prc.ast.sons[resultPos].sym
    resultAsgn = ("var $# = $#;$n" | "local $# = $#;$n") % [
        mangleName(resultSym),
        createVar(p, resultSym.typ, isIndirect(resultSym))]
    gen(p, prc.ast.sons[resultPos], a)
    if mapType(resultSym.typ) == etyBaseIndex:
      returnStmt = "return [$#, $#];$n" % [a.address, a.res]
    else:
      returnStmt = "return $#;$n" % [a.res]
  genStmt(p, prc.getBody)
  result = ("function $#($#) {$n$#$#$#$#}$n" |
            "function $#($#) $n$#$#$#$#$nend$n") %
            [name, header, p.locals, resultAsgn,
             genProcBody(p, prc), returnStmt]
  #if gVerbosity >= 3:
  #  echo "END   generated code for: " & prc.name.s

proc genStmt(p: PProc, n: PNode) =
  var r: TCompRes
  gen(p, n, r)
  if r.res != nil: addf(p.body, "$#;$n", [r.res])

proc genPragma(p: PProc, n: PNode) =
  for it in n.sons:
    case whichPragma(it)
    of wEmit: genAsmOrEmitStmt(p, it.sons[1])
    else: discard

proc gen(p: PProc, n: PNode, r: var TCompRes) =
  r.typ = etyNone
  r.kind = resNone
  #r.address = nil
  r.res = nil
  case n.kind
  of nkSym:
    genSym(p, n, r)
  of nkCharLit..nkInt64Lit:
    r.res = rope(n.intVal)
    r.kind = resExpr
  of nkNilLit:
    if isEmptyType(n.typ):
      discard
    elif mapType(n.typ) == etyBaseIndex:
      r.typ = etyBaseIndex
      r.address = rope"null" | rope"nil"
      r.res = rope"0"
      r.kind = resExpr
    else:
      r.res = rope"null" | rope"nil"
      r.kind = resExpr
  of nkStrLit..nkTripleStrLit:
    if skipTypes(n.typ, abstractVarRange).kind == tyString:
      useMagic(p, "cstrToNimstr")
      r.res = "cstrToNimstr($1)" % [makeJSString(n.strVal)]
    else:
      r.res = makeJSString(n.strVal)
    r.kind = resExpr
  of nkFloatLit..nkFloat64Lit:
    let f = n.floatVal
    if f != f: r.res = rope"NaN"
    elif f == 0.0: r.res = rope"0.0"
    elif f == 0.5 * f:
      if f > 0.0: r.res = rope"Infinity"
      else: r.res = rope"-Infinity"
    else: r.res = rope(f.toStrMaxPrecision)
    r.kind = resExpr
  of nkCallKinds:
    if (n.sons[0].kind == nkSym) and (n.sons[0].sym.magic != mNone):
      genMagic(p, n, r)
    elif n.sons[0].kind == nkSym and sfInfixCall in n.sons[0].sym.flags and
        n.len >= 2:
      genInfixCall(p, n, r)
    else:
      genCall(p, n, r)
  of nkCurly: genSetConstr(p, n, r)
  of nkBracket: genArrayConstr(p, n, r)
  of nkPar: genTupleConstr(p, n, r)
  of nkObjConstr: genObjConstr(p, n, r)
  of nkHiddenStdConv, nkHiddenSubConv, nkConv: genConv(p, n, r)
  of nkAddr, nkHiddenAddr: genAddr(p, n, r)
  of nkDerefExpr, nkHiddenDeref: genDeref(p, n, r)
  of nkBracketExpr: genArrayAccess(p, n, r)
  of nkDotExpr: genFieldAccess(p, n, r)
  of nkCheckedFieldExpr: genCheckedFieldAccess(p, n, r)
  of nkObjDownConv: gen(p, n.sons[0], r)
  of nkObjUpConv: upConv(p, n, r)
  of nkCast: gen(p, n.sons[1], r)
  of nkChckRangeF: genRangeChck(p, n, r, "chckRangeF")
  of nkChckRange64: genRangeChck(p, n, r, "chckRange64")
  of nkChckRange: genRangeChck(p, n, r, "chckRange")
  of nkStringToCString: convStrToCStr(p, n, r)
  of nkCStringToString: convCStrToStr(p, n, r)
  of nkEmpty: discard
  of nkLambdaKinds:
    let s = n.sons[namePos].sym
    discard mangleName(s)
    r.res = s.loc.r
    if lfNoDecl in s.loc.flags or s.magic != mNone: discard
    elif not p.g.generatedSyms.containsOrIncl(s.id):
      add(p.locals, genProc(p, s))
  of nkType: r.res = genTypeInfo(p, n.typ)
  of nkStmtList, nkStmtListExpr:
    # this shows the distinction is nice for backends and should be kept
    # in the frontend
    let isExpr = not isEmptyType(n.typ)
    for i in countup(0, sonsLen(n) - 1 - isExpr.ord):
      genStmt(p, n.sons[i])
    if isExpr:
      gen(p, lastSon(n), r)
  of nkBlockStmt, nkBlockExpr: genBlock(p, n, r)
  of nkIfStmt, nkIfExpr: genIf(p, n, r)
  of nkWhen:
    # This is "when nimvm" node
    gen(p, n.sons[1].sons[0], r)
  of nkWhileStmt: genWhileStmt(p, n)
  of nkVarSection, nkLetSection: genVarStmt(p, n)
  of nkConstSection: discard
  of nkForStmt, nkParForStmt:
    internalError(n.info, "for statement not eliminated")
  of nkCaseStmt:
    if p.target == targetJS: genCaseJS(p, n, r)
    else: genCaseLua(p, n, r)
  of nkReturnStmt: genReturnStmt(p, n)
  of nkBreakStmt: genBreakStmt(p, n)
  of nkAsgn: genAsgn(p, n)
  of nkFastAsgn: genFastAsgn(p, n)
  of nkDiscardStmt:
    if n.sons[0].kind != nkEmpty:
      genLineDir(p, n)
      gen(p, n.sons[0], r)
  of nkAsmStmt: genAsmOrEmitStmt(p, n)
  of nkTryStmt: genTry(p, n, r)
  of nkRaiseStmt: genRaiseStmt(p, n)
  of nkTypeSection, nkCommentStmt, nkIteratorDef, nkIncludeStmt,
     nkImportStmt, nkImportExceptStmt, nkExportStmt, nkExportExceptStmt,
     nkFromStmt, nkTemplateDef, nkMacroDef: discard
  of nkPragma: genPragma(p, n)
  of nkProcDef, nkMethodDef, nkConverterDef:
    var s = n.sons[namePos].sym
    if {sfExportc, sfCompilerProc} * s.flags == {sfExportc}:
      genSym(p, n.sons[namePos], r)
      r.res = nil
  of nkGotoState, nkState:
    internalError(n.info, "first class iterators not implemented")
  of nkPragmaBlock: gen(p, n.lastSon, r)
  else: internalError(n.info, "gen: unknown node type: " & $n.kind)

var globals: PGlobals

proc newModule(module: PSym): BModule =
  new(result)
  result.module = module
  if globals == nil: globals = newGlobals()

proc genHeader(): Rope =
  result = ("/* Generated by the Nim Compiler v$1 */$n" &
            "/*   (c) 2015 Andreas Rumpf */$n$n" &
            "var framePtr = null;$n" &
            "var excHandler = 0;$n" &
            "var lastJSError = null;$n") %
           [rope(VersionAsString)]

proc genModule(p: PProc, n: PNode) =
  if optStackTrace in p.options:
    addf(p.body, "var F = {procname:$1,prev:framePtr,filename:$2,line:0};$n" &
                 "framePtr = F;$n", [
        makeJSString("module " & p.module.module.name.s),
        makeJSString(toFilename(p.module.module.info))])
  genStmt(p, n)
  if optStackTrace in p.options:
    addf(p.body, "framePtr = framePtr.prev;$n", [])

proc myProcess(b: PPassContext, n: PNode): PNode =
  if passes.skipCodegen(n): return n
  result = n
  var m = BModule(b)
  if m.module == nil: internalError(n.info, "myProcess")
  var p = newProc(globals, m, nil, m.module.options)
  genModule(p, n)
  add(p.g.code, p.locals)
  add(p.g.code, p.body)

proc wholeCode*(m: BModule): Rope =
  for prc in globals.forwarded:
    if not globals.generatedSyms.containsOrIncl(prc.id):
      var p = newProc(globals, m, nil, m.module.options)
      add(p.g.code, genProc(p, prc))

  var disp = generateMethodDispatchers()
  for i in 0..sonsLen(disp)-1:
    let prc = disp.sons[i].sym
    if not globals.generatedSyms.containsOrIncl(prc.id):
      var p = newProc(globals, m, nil, m.module.options)
      add(p.g.code, genProc(p, prc))

  result = globals.typeInfo & globals.code

proc myClose(b: PPassContext, n: PNode): PNode =
  if passes.skipCodegen(n): return n
  result = myProcess(b, n)
  var m = BModule(b)
  if sfMainModule in m.module.flags:
    let code = wholeCode(m)
    let outfile =
      if options.outFile.len > 0:
        if options.outFile.isAbsolute: options.outFile
        else: getCurrentDir() / options.outFile
      else:
       changeFileExt(completeCFilePath(m.module.filename), "js")
    discard writeRopeIfNotEqual(genHeader() & code, outfile)

proc myOpenCached(s: PSym, rd: PRodReader): PPassContext =
  internalError("symbol files are not possible with the JS code generator")
  result = nil

proc myOpen(s: PSym): PPassContext =
  result = newModule(s)

const JSgenPass* = makePass(myOpen, myOpenCached, myProcess, myClose)

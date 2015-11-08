#
#
#           The Nim Compiler
#        (c) Copyright 2015 Andreas Rumpf
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.
#

## This module implements the code generator for the VM.

# Important things to remember:
# - The VM does not distinguish between definitions ('var x = y') and
#   assignments ('x = y'). For simple data types that fit into a register
#   this doesn't matter. However it matters for strings and other complex
#   types that use the 'node' field; the reason is that slots are
#   re-used in a register based VM. Example:
#
# .. code-block:: nim
#   let s = a & b  # no matter what, create fresh node
#   s = a & b  # no matter what, keep the node
#
# Also *stores* into non-temporary memory need to perform deep copies:
# a.b = x.y
# We used to generate opcAsgn for the *load* of 'x.y' but this is clearly
# wrong! We need to produce opcAsgn (the copy) for the *store*. This also
# solves the opcLdConst vs opcAsgnConst issue. Of course whether we need
# this copy depends on the involved types.

import
  unsigned, strutils, ast, astalgo, types, msgs, renderer, vmdef,
  trees, intsets, rodread, magicsys, options, lowerings

from os import splitFile

when hasFFI:
  import evalffi

type
  TGenFlag = enum gfAddrOf, gfFieldAccess
  TGenFlags = set[TGenFlag]

proc debugInfo(info: TLineInfo): string =
  result = info.toFilename.splitFile.name & ":" & $info.line

proc codeListing(c: PCtx, result: var string, start=0; last = -1) =
  # first iteration: compute all necessary labels:
  var jumpTargets = initIntSet()
  let last = if last < 0: c.code.len-1 else: min(last, c.code.len-1)
  for i in start..last:
    let x = c.code[i]
    if x.opcode in relativeJumps:
      jumpTargets.incl(i+x.regBx-wordExcess)

  # for debugging purposes
  var i = start
  while i <= last:
    if i in jumpTargets: result.addf("L$1:\n", i)
    let x = c.code[i]

    result.add($i)
    let opc = opcode(x)
    if opc in {opcConv, opcCast}:
      let y = c.code[i+1]
      let z = c.code[i+2]
      result.addf("\t$#\tr$#, r$#, $#, $#", ($opc).substr(3), x.regA, x.regB,
        c.types[y.regBx-wordExcess].typeToString,
        c.types[z.regBx-wordExcess].typeToString)
      inc i, 2
    elif opc < firstABxInstr:
      result.addf("\t$#\tr$#, r$#, r$#", ($opc).substr(3), x.regA,
                  x.regB, x.regC)
    elif opc in relativeJumps:
      result.addf("\t$#\tr$#, L$#", ($opc).substr(3), x.regA,
                  i+x.regBx-wordExcess)
    elif opc in {opcLdConst, opcAsgnConst}:
      let idx = x.regBx-wordExcess
      result.addf("\t$#\tr$#, $# ($#)", ($opc).substr(3), x.regA,
        c.constants[idx].renderTree, $idx)
    elif opc in {opcMarshalLoad, opcMarshalStore}:
      let y = c.code[i+1]
      result.addf("\t$#\tr$#, r$#, $#", ($opc).substr(3), x.regA, x.regB,
        c.types[y.regBx-wordExcess].typeToString)
      inc i
    else:
      result.addf("\t$#\tr$#, $#", ($opc).substr(3), x.regA, x.regBx-wordExcess)
    result.add("\t#")
    result.add(debugInfo(c.debug[i]))
    result.add("\n")
    inc i

proc echoCode*(c: PCtx; start=0; last = -1) {.deprecated.} =
  var buf = ""
  codeListing(c, buf, start, last)
  echo buf

proc gABC(ctx: PCtx; n: PNode; opc: TOpcode; a, b, c: TRegister = 0) =
  ## Takes the registers `b` and `c`, applies the operation `opc` to them, and
  ## stores the result into register `a`
  ## The node is needed for debug information
  assert opc.ord < 255
  let ins = (opc.uint32 or (a.uint32 shl 8'u32) or
                           (b.uint32 shl 16'u32) or
                           (c.uint32 shl 24'u32)).TInstr
  ctx.code.add(ins)
  ctx.debug.add(n.info)

proc gABI(c: PCtx; n: PNode; opc: TOpcode; a, b: TRegister; imm: BiggestInt) =
  # Takes the `b` register and the immediate `imm`, appies the operation `opc`,
  # and stores the output value into `a`.
  # `imm` is signed and must be within [-127, 128]
  if imm >= -127 and imm <= 128:
    let ins = (opc.uint32 or (a.uint32 shl 8'u32) or
                             (b.uint32 shl 16'u32) or
                             (imm+byteExcess).uint32 shl 24'u32).TInstr
    c.code.add(ins)
    c.debug.add(n.info)
  else:
    localError(n.info, errGenerated,
      "VM: immediate value does not fit into an int8")

proc gABx(c: PCtx; n: PNode; opc: TOpcode; a: TRegister = 0; bx: int) =
  # Applies `opc` to `bx` and stores it into register `a`
  # `bx` must be signed and in the range [-32767, 32768]
  if bx >= -32767 and bx <= 32768:
    let ins = (opc.uint32 or a.uint32 shl 8'u32 or
              (bx+wordExcess).uint32 shl 16'u32).TInstr
    c.code.add(ins)
    c.debug.add(n.info)
  else:
    localError(n.info, errGenerated,
      "VM: immediate value does not fit into an int16")

proc xjmp(c: PCtx; n: PNode; opc: TOpcode; a: TRegister = 0): TPosition =
  #assert opc in {opcJmp, opcFJmp, opcTJmp}
  result = TPosition(c.code.len)
  gABx(c, n, opc, a, 0)

proc genLabel(c: PCtx): TPosition =
  result = TPosition(c.code.len)
  #c.jumpTargets.incl(c.code.len)

proc jmpBack(c: PCtx, n: PNode, p = TPosition(0)) =
  let dist = p.int - c.code.len
  internalAssert(-0x7fff < dist and dist < 0x7fff)
  gABx(c, n, opcJmpBack, 0, dist)

proc patch(c: PCtx, p: TPosition) =
  # patch with current index
  let p = p.int
  let diff = c.code.len - p
  #c.jumpTargets.incl(c.code.len)
  internalAssert(-0x7fff < diff and diff < 0x7fff)
  let oldInstr = c.code[p]
  # opcode and regA stay the same:
  c.code[p] = ((oldInstr.uint32 and 0xffff'u32).uint32 or
               uint32(diff+wordExcess) shl 16'u32).TInstr

proc getSlotKind(t: PType): TSlotKind =
  case t.skipTypes(abstractRange-{tyTypeDesc}).kind
  of tyBool, tyChar, tyEnum, tyOrdinal, tyInt..tyInt64, tyUInt..tyUInt64:
    slotTempInt
  of tyString, tyCString:
    slotTempStr
  of tyFloat..tyFloat128:
    slotTempFloat
  else:
    slotTempComplex

const
  HighRegisterPressure = 40

proc bestEffort(c: PCtx): TLineInfo =
  (if c.prc == nil: c.module.info else: c.prc.sym.info)

proc getTemp(cc: PCtx; tt: PType): TRegister =
  let typ = tt.skipTypesOrNil({tyStatic})
  let c = cc.prc
  # we prefer the same slot kind here for efficiency. Unfortunately for
  # discardable return types we may not know the desired type. This can happen
  # for e.g. mNAdd[Multiple]:
  let k = if typ.isNil: slotTempComplex else: typ.getSlotKind
  for i in 0 .. c.maxSlots-1:
    if c.slots[i].kind == k and not c.slots[i].inUse:
      c.slots[i].inUse = true
      return TRegister(i)

  # if register pressure is high, we re-use more aggressively:
  if c.maxSlots >= HighRegisterPressure and false:
    for i in 0 .. c.maxSlots-1:
      if not c.slots[i].inUse:
        c.slots[i] = (inUse: true, kind: k)
        return TRegister(i)
  if c.maxSlots >= high(TRegister):
    globalError(cc.bestEffort, "VM problem: too many registers required")
  result = TRegister(c.maxSlots)
  c.slots[c.maxSlots] = (inUse: true, kind: k)
  inc c.maxSlots

proc freeTemp(c: PCtx; r: TRegister) =
  let c = c.prc
  if c.slots[r].kind in {slotSomeTemp..slotTempComplex}: c.slots[r].inUse = false

proc getTempRange(cc: PCtx; n: int; kind: TSlotKind): TRegister =
  # if register pressure is high, we re-use more aggressively:
  let c = cc.prc
  if c.maxSlots >= HighRegisterPressure or c.maxSlots+n >= high(TRegister):
    for i in 0 .. c.maxSlots-n:
      if not c.slots[i].inUse:
        block search:
          for j in i+1 .. i+n-1:
            if c.slots[j].inUse: break search
          result = TRegister(i)
          for k in result .. result+n-1: c.slots[k] = (inUse: true, kind: kind)
          return
  if c.maxSlots+n >= high(TRegister):
    globalError(cc.bestEffort, "VM problem: too many registers required")
  result = TRegister(c.maxSlots)
  inc c.maxSlots, n
  for k in result .. result+n-1: c.slots[k] = (inUse: true, kind: kind)

proc freeTempRange(c: PCtx; start: TRegister, n: int) =
  for i in start .. start+n-1: c.freeTemp(TRegister(i))

template withTemp(tmp, typ: expr, body: stmt) {.immediate, dirty.} =
  var tmp = getTemp(c, typ)
  body
  c.freeTemp(tmp)

proc popBlock(c: PCtx; oldLen: int) =
  for f in c.prc.blocks[oldLen].fixups:
    c.patch(f)
  c.prc.blocks.setLen(oldLen)

template withBlock(labl: PSym; body: stmt) {.immediate, dirty.} =
  var oldLen {.gensym.} = c.prc.blocks.len
  c.prc.blocks.add TBlock(label: labl, fixups: @[])
  body
  popBlock(c, oldLen)

proc gen(c: PCtx; n: PNode; dest: var TDest; flags: TGenFlags = {})
proc gen(c: PCtx; n: PNode; dest: TRegister; flags: TGenFlags = {}) =
  var d: TDest = dest
  gen(c, n, d, flags)
  internalAssert d == dest

proc gen(c: PCtx; n: PNode; flags: TGenFlags = {}) =
  var tmp: TDest = -1
  gen(c, n, tmp, flags)
  #if n.typ.isEmptyType: InternalAssert tmp < 0

proc genx(c: PCtx; n: PNode; flags: TGenFlags = {}): TRegister =
  var tmp: TDest = -1
  gen(c, n, tmp, flags)
  internalAssert tmp >= 0
  result = TRegister(tmp)

proc clearDest(c: PCtx; n: PNode; dest: var TDest) {.inline.} =
  # stmt is different from 'void' in meta programming contexts.
  # So we only set dest to -1 if 'void':
  if dest >= 0 and (n.typ.isNil or n.typ.kind == tyEmpty):
    c.freeTemp(dest)
    dest = -1

proc isNotOpr(n: PNode): bool =
  n.kind in nkCallKinds and n.sons[0].kind == nkSym and
    n.sons[0].sym.magic == mNot

proc isTrue(n: PNode): bool =
  n.kind == nkSym and n.sym.kind == skEnumField and n.sym.position != 0 or
    n.kind == nkIntLit and n.intVal != 0

proc genWhile(c: PCtx; n: PNode) =
  # L1:
  #   cond, tmp
  #   fjmp tmp, L2
  #   body
  #   jmp L1
  # L2:
  let L1 = c.genLabel
  withBlock(nil):
    if isTrue(n.sons[0]):
      c.gen(n.sons[1])
      c.jmpBack(n, L1)
    elif isNotOpr(n.sons[0]):
      var tmp = c.genx(n.sons[0].sons[1])
      let L2 = c.xjmp(n, opcTJmp, tmp)
      c.freeTemp(tmp)
      c.gen(n.sons[1])
      c.jmpBack(n, L1)
      c.patch(L2)
    else:
      var tmp = c.genx(n.sons[0])
      let L2 = c.xjmp(n, opcFJmp, tmp)
      c.freeTemp(tmp)
      c.gen(n.sons[1])
      c.jmpBack(n, L1)
      c.patch(L2)

proc genBlock(c: PCtx; n: PNode; dest: var TDest) =
  withBlock(n.sons[0].sym):
    c.gen(n.sons[1], dest)
  c.clearDest(n, dest)

proc genBreak(c: PCtx; n: PNode) =
  let L1 = c.xjmp(n, opcJmp)
  if n.sons[0].kind == nkSym:
    #echo cast[int](n.sons[0].sym)
    for i in countdown(c.prc.blocks.len-1, 0):
      if c.prc.blocks[i].label == n.sons[0].sym:
        c.prc.blocks[i].fixups.add L1
        return
    globalError(n.info, errGenerated, "VM problem: cannot find 'break' target")
  else:
    c.prc.blocks[c.prc.blocks.high].fixups.add L1

proc genIf(c: PCtx, n: PNode; dest: var TDest) =
  #  if (!expr1) goto L1;
  #    thenPart
  #    goto LEnd
  #  L1:
  #  if (!expr2) goto L2;
  #    thenPart2
  #    goto LEnd
  #  L2:
  #    elsePart
  #  Lend:
  if dest < 0 and not isEmptyType(n.typ): dest = getTemp(c, n.typ)
  var endings: seq[TPosition] = @[]
  for i in countup(0, len(n) - 1):
    var it = n.sons[i]
    if it.len == 2:
      withTemp(tmp, it.sons[0].typ):
        var elsePos: TPosition
        if isNotOpr(it.sons[0]):
          c.gen(it.sons[0].sons[1], tmp)
          elsePos = c.xjmp(it.sons[0].sons[1], opcTJmp, tmp) # if true
        else:
          c.gen(it.sons[0], tmp)
          elsePos = c.xjmp(it.sons[0], opcFJmp, tmp) # if false
      c.clearDest(n, dest)
      c.gen(it.sons[1], dest) # then part
      if i < sonsLen(n)-1:
        endings.add(c.xjmp(it.sons[1], opcJmp, 0))
      c.patch(elsePos)
    else:
      c.clearDest(n, dest)
      c.gen(it.sons[0], dest)
  for endPos in endings: c.patch(endPos)
  c.clearDest(n, dest)

proc genAndOr(c: PCtx; n: PNode; opc: TOpcode; dest: var TDest) =
  #   asgn dest, a
  #   tjmp|fjmp L1
  #   asgn dest, b
  # L1:
  if dest < 0: dest = getTemp(c, n.typ)
  c.gen(n.sons[1], dest)
  let L1 = c.xjmp(n, opc, dest)
  c.gen(n.sons[2], dest)
  c.patch(L1)

proc canonValue*(n: PNode): PNode =
  result = n

proc rawGenLiteral(c: PCtx; n: PNode): int =
  result = c.constants.len
  assert(n.kind != nkCall)
  n.flags.incl nfAllConst
  c.constants.add n.canonValue
  internalAssert result < 0x7fff

proc sameConstant*(a, b: PNode): bool =
  result = false
  if a == b:
    result = true
  elif a != nil and b != nil and a.kind == b.kind:
    case a.kind
    of nkSym: result = a.sym == b.sym
    of nkIdent: result = a.ident.id == b.ident.id
    of nkCharLit..nkUInt64Lit: result = a.intVal == b.intVal
    of nkFloatLit..nkFloat64Lit: result = a.floatVal == b.floatVal
    of nkStrLit..nkTripleStrLit: result = a.strVal == b.strVal
    of nkType, nkNilLit: result = a.typ == b.typ
    of nkEmpty: result = true
    else:
      if sonsLen(a) == sonsLen(b):
        for i in countup(0, sonsLen(a) - 1):
          if not sameConstant(a.sons[i], b.sons[i]): return
        result = true

proc genLiteral(c: PCtx; n: PNode): int =
  # types do not matter here:
  for i in 0 .. <c.constants.len:
    if sameConstant(c.constants[i], n): return i
  result = rawGenLiteral(c, n)

proc unused(n: PNode; x: TDest) {.inline.} =
  if x >= 0:
    #debug(n)
    globalError(n.info, "not unused")

proc genCase(c: PCtx; n: PNode; dest: var TDest) =
  #  if (!expr1) goto L1;
  #    thenPart
  #    goto LEnd
  #  L1:
  #  if (!expr2) goto L2;
  #    thenPart2
  #    goto LEnd
  #  L2:
  #    elsePart
  #  Lend:
  if not isEmptyType(n.typ):
    if dest < 0: dest = getTemp(c, n.typ)
  else:
    unused(n, dest)
  var endings: seq[TPosition] = @[]
  withTemp(tmp, n.sons[0].typ):
    c.gen(n.sons[0], tmp)
    # branch tmp, codeIdx
    # fjmp   elseLabel
    for i in 1 .. <n.len:
      let it = n.sons[i]
      if it.len == 1:
        # else stmt:
        c.gen(it.sons[0], dest)
      else:
        let b = rawGenLiteral(c, it)
        c.gABx(it, opcBranch, tmp, b)
        let elsePos = c.xjmp(it.lastSon, opcFJmp, tmp)
        c.gen(it.lastSon, dest)
        if i < sonsLen(n)-1:
          endings.add(c.xjmp(it.lastSon, opcJmp, 0))
        c.patch(elsePos)
      c.clearDest(n, dest)
  for endPos in endings: c.patch(endPos)

proc genType(c: PCtx; typ: PType): int =
  for i, t in c.types:
    if sameType(t, typ): return i
  result = c.types.len
  c.types.add(typ)
  internalAssert(result <= 0x7fff)

proc genTry(c: PCtx; n: PNode; dest: var TDest) =
  if dest < 0 and not isEmptyType(n.typ): dest = getTemp(c, n.typ)
  var endings: seq[TPosition] = @[]
  let elsePos = c.xjmp(n, opcTry, 0)
  c.gen(n.sons[0], dest)
  c.clearDest(n, dest)
  c.patch(elsePos)
  for i in 1 .. <n.len:
    let it = n.sons[i]
    if it.kind != nkFinally:
      var blen = len(it)
      # first opcExcept contains the end label of the 'except' block:
      let endExcept = c.xjmp(it, opcExcept, 0)
      for j in countup(0, blen - 2):
        assert(it.sons[j].kind == nkType)
        let typ = it.sons[j].typ.skipTypes(abstractPtrs-{tyTypeDesc})
        c.gABx(it, opcExcept, 0, c.genType(typ))
      if blen == 1:
        # general except section:
        c.gABx(it, opcExcept, 0, 0)
      c.gen(it.lastSon, dest)
      c.clearDest(n, dest)
      if i < sonsLen(n)-1:
        endings.add(c.xjmp(it, opcJmp, 0))
      c.patch(endExcept)
  for endPos in endings: c.patch(endPos)
  let fin = lastSon(n)
  # we always generate an 'opcFinally' as that pops the safepoint
  # from the stack
  c.gABx(fin, opcFinally, 0, 0)
  if fin.kind == nkFinally:
    c.gen(fin.sons[0])
    c.clearDest(n, dest)
  c.gABx(fin, opcFinallyEnd, 0, 0)

proc genRaise(c: PCtx; n: PNode) =
  let dest = genx(c, n.sons[0])
  c.gABC(n, opcRaise, dest)
  c.freeTemp(dest)

proc genReturn(c: PCtx; n: PNode) =
  if n.sons[0].kind != nkEmpty:
    gen(c, n.sons[0])
  c.gABC(n, opcRet)

proc genCall(c: PCtx; n: PNode; dest: var TDest) =
  if dest < 0 and not isEmptyType(n.typ): dest = getTemp(c, n.typ)
  let x = c.getTempRange(n.len, slotTempUnknown)
  # varargs need 'opcSetType' for the FFI support:
  let fntyp = n.sons[0].typ
  for i in 0.. <n.len:
    var r: TRegister = x+i
    c.gen(n.sons[i], r)
    if i >= fntyp.len:
      internalAssert tfVarargs in fntyp.flags
      c.gABx(n, opcSetType, r, c.genType(n.sons[i].typ))
  if dest < 0:
    c.gABC(n, opcIndCall, 0, x, n.len)
  else:
    c.gABC(n, opcIndCallAsgn, dest, x, n.len)
  c.freeTempRange(x, n.len)

template isGlobal(s: PSym): bool = sfGlobal in s.flags and s.kind != skForVar
proc isGlobal(n: PNode): bool = n.kind == nkSym and isGlobal(n.sym)

proc needsAsgnPatch(n: PNode): bool =
  n.kind in {nkBracketExpr, nkDotExpr, nkCheckedFieldExpr,
             nkDerefExpr, nkHiddenDeref} or (n.kind == nkSym and n.sym.isGlobal)

proc genField(n: PNode): TRegister =
  if n.kind != nkSym or n.sym.kind != skField:
    globalError(n.info, "no field symbol")
  let s = n.sym
  if s.position > high(result):
    globalError(n.info,
        "too large offset! cannot generate code for: " & s.name.s)
  result = s.position

proc genIndex(c: PCtx; n: PNode; arr: PType): TRegister =
  if arr.skipTypes(abstractInst).kind == tyArray and (let x = firstOrd(arr);
      x != 0):
    let tmp = c.genx(n)
    # freeing the temporary here means we can produce:  regA = regA - Imm
    c.freeTemp(tmp)
    result = c.getTemp(n.typ)
    c.gABI(n, opcSubImmInt, result, tmp, x.int)
  else:
    result = c.genx(n)

proc genAsgnPatch(c: PCtx; le: PNode, value: TRegister) =
  case le.kind
  of nkBracketExpr:
    let dest = c.genx(le.sons[0], {gfAddrOf, gfFieldAccess})
    let idx = c.genIndex(le.sons[1], le.sons[0].typ)
    c.gABC(le, opcWrArr, dest, idx, value)
    c.freeTemp(dest)
    c.freeTemp(idx)
  of nkDotExpr, nkCheckedFieldExpr:
    # XXX field checks here
    let left = if le.kind == nkDotExpr: le else: le.sons[0]
    let dest = c.genx(left.sons[0], {gfAddrOf, gfFieldAccess})
    let idx = genField(left.sons[1])
    c.gABC(left, opcWrObj, dest, idx, value)
    c.freeTemp(dest)
  of nkDerefExpr, nkHiddenDeref:
    let dest = c.genx(le.sons[0], {gfAddrOf})
    c.gABC(le, opcWrDeref, dest, 0, value)
    c.freeTemp(dest)
  of nkSym:
    if le.sym.isGlobal:
      let dest = c.genx(le, {gfAddrOf})
      c.gABC(le, opcWrDeref, dest, 0, value)
      c.freeTemp(dest)
  else:
    discard

proc genNew(c: PCtx; n: PNode) =
  let dest = if needsAsgnPatch(n.sons[1]): c.getTemp(n.sons[1].typ)
             else: c.genx(n.sons[1])
  # we use the ref's base type here as the VM conflates 'ref object'
  # and 'object' since internally we already have a pointer.
  c.gABx(n, opcNew, dest,
         c.genType(n.sons[1].typ.skipTypes(abstractVar-{tyTypeDesc}).sons[0]))
  c.genAsgnPatch(n.sons[1], dest)
  c.freeTemp(dest)

proc genNewSeq(c: PCtx; n: PNode) =
  let dest = if needsAsgnPatch(n.sons[1]): c.getTemp(n.sons[1].typ)
             else: c.genx(n.sons[1])
  let tmp = c.genx(n.sons[2])
  c.gABx(n, opcNewSeq, dest, c.genType(n.sons[1].typ.skipTypes(
                                                  abstractVar-{tyTypeDesc})))
  c.gABx(n, opcNewSeq, tmp, 0)
  c.freeTemp(tmp)
  c.genAsgnPatch(n.sons[1], dest)
  c.freeTemp(dest)

proc genUnaryABC(c: PCtx; n: PNode; dest: var TDest; opc: TOpcode) =
  let tmp = c.genx(n.sons[1])
  if dest < 0: dest = c.getTemp(n.typ)
  c.gABC(n, opc, dest, tmp)
  c.freeTemp(tmp)

proc genUnaryABI(c: PCtx; n: PNode; dest: var TDest; opc: TOpcode) =
  let tmp = c.genx(n.sons[1])
  if dest < 0: dest = c.getTemp(n.typ)
  c.gABI(n, opc, dest, tmp, 0)
  c.freeTemp(tmp)

proc genBinaryABC(c: PCtx; n: PNode; dest: var TDest; opc: TOpcode) =
  let
    tmp = c.genx(n.sons[1])
    tmp2 = c.genx(n.sons[2])
  if dest < 0: dest = c.getTemp(n.typ)
  c.gABC(n, opc, dest, tmp, tmp2)
  c.freeTemp(tmp)
  c.freeTemp(tmp2)

proc genBinaryABCD(c: PCtx; n: PNode; dest: var TDest; opc: TOpcode) =
  let
    tmp = c.genx(n.sons[1])
    tmp2 = c.genx(n.sons[2])
    tmp3 = c.genx(n.sons[3])
  if dest < 0: dest = c.getTemp(n.typ)
  c.gABC(n, opc, dest, tmp, tmp2)
  c.gABC(n, opc, tmp3)
  c.freeTemp(tmp)
  c.freeTemp(tmp2)
  c.freeTemp(tmp3)

proc genNarrow(c: PCtx; n: PNode; dest: TDest) =
  let t = skipTypes(n.typ, abstractVar-{tyTypeDesc})
  # uint is uint64 in the VM, we we only need to mask the result for
  # other unsigned types:
  if t.kind in {tyUInt8..tyUInt32}:
    c.gABC(n, opcNarrowU, dest, TRegister(t.size*8))
  elif t.kind in {tyInt8..tyInt32}:
    c.gABC(n, opcNarrowS, dest, TRegister(t.size*8))

proc genNarrowU(c: PCtx; n: PNode; dest: TDest) =
  let t = skipTypes(n.typ, abstractVar-{tyTypeDesc})
  # uint is uint64 in the VM, we we only need to mask the result for
  # other unsigned types:
  if t.kind in {tyUInt8..tyUInt32, tyInt8..tyInt32} or
      (t.kind == tyInt and t.size == 4):
    c.gABC(n, opcNarrowU, dest, TRegister(t.size*8))

proc genBinaryABCnarrow(c: PCtx; n: PNode; dest: var TDest; opc: TOpcode) =
  genBinaryABC(c, n, dest, opc)
  genNarrow(c, n, dest)

proc genBinaryABCnarrowU(c: PCtx; n: PNode; dest: var TDest; opc: TOpcode) =
  genBinaryABC(c, n, dest, opc)
  genNarrowU(c, n, dest)

proc genSetType(c: PCtx; n: PNode; dest: TRegister) =
  let t = skipTypes(n.typ, abstractInst-{tyTypeDesc})
  if t.kind == tySet:
    c.gABx(n, opcSetType, dest, c.genType(t))

proc genBinarySet(c: PCtx; n: PNode; dest: var TDest; opc: TOpcode) =
  let
    tmp = c.genx(n.sons[1])
    tmp2 = c.genx(n.sons[2])
  if dest < 0: dest = c.getTemp(n.typ)
  c.genSetType(n.sons[1], tmp)
  c.genSetType(n.sons[2], tmp2)
  c.gABC(n, opc, dest, tmp, tmp2)
  c.freeTemp(tmp)
  c.freeTemp(tmp2)

proc genBinaryStmt(c: PCtx; n: PNode; opc: TOpcode) =
  let
    dest = c.genx(n.sons[1])
    tmp = c.genx(n.sons[2])
  c.gABC(n, opc, dest, tmp, 0)
  c.freeTemp(tmp)

proc genBinaryStmtVar(c: PCtx; n: PNode; opc: TOpcode) =
  var x = n.sons[1]
  if x.kind in {nkAddr, nkHiddenAddr}: x = x.sons[0]
  let
    dest = c.genx(x)
    tmp = c.genx(n.sons[2])
  c.gABC(n, opc, dest, tmp, 0)
  #c.genAsgnPatch(n.sons[1], dest)
  c.freeTemp(tmp)

proc genUnaryStmt(c: PCtx; n: PNode; opc: TOpcode) =
  let tmp = c.genx(n.sons[1])
  c.gABC(n, opc, tmp, 0, 0)
  c.freeTemp(tmp)

proc genVarargsABC(c: PCtx; n: PNode; dest: var TDest; opc: TOpcode) =
  if dest < 0: dest = getTemp(c, n.typ)
  var x = c.getTempRange(n.len-1, slotTempStr)
  for i in 1..n.len-1:
    var r: TRegister = x+i-1
    c.gen(n.sons[i], r)
  c.gABC(n, opc, dest, x, n.len-1)
  c.freeTempRange(x, n.len)

proc isInt8Lit(n: PNode): bool =
  if n.kind in {nkCharLit..nkUInt64Lit}:
    result = n.intVal >= low(int8) and n.intVal <= high(int8)

proc isInt16Lit(n: PNode): bool =
  if n.kind in {nkCharLit..nkUInt64Lit}:
    result = n.intVal >= low(int16) and n.intVal <= high(int16)

proc genAddSubInt(c: PCtx; n: PNode; dest: var TDest; opc: TOpcode) =
  if n.sons[2].isInt8Lit:
    let tmp = c.genx(n.sons[1])
    if dest < 0: dest = c.getTemp(n.typ)
    c.gABI(n, succ(opc), dest, tmp, n.sons[2].intVal)
    c.freeTemp(tmp)
  else:
    genBinaryABC(c, n, dest, opc)
  c.genNarrow(n, dest)

proc genConv(c: PCtx; n, arg: PNode; dest: var TDest; opc=opcConv) =
  let tmp = c.genx(arg)
  if dest < 0: dest = c.getTemp(n.typ)
  c.gABC(n, opc, dest, tmp)
  c.gABx(n, opc, 0, genType(c, n.typ))
  c.gABx(n, opc, 0, genType(c, arg.typ.skipTypes({tyStatic})))
  c.freeTemp(tmp)

proc genCard(c: PCtx; n: PNode; dest: var TDest) =
  let tmp = c.genx(n.sons[1])
  if dest < 0: dest = c.getTemp(n.typ)
  c.genSetType(n.sons[1], tmp)
  c.gABC(n, opcCard, dest, tmp)
  c.freeTemp(tmp)

proc genMagic(c: PCtx; n: PNode; dest: var TDest; m: TMagic) =
  case m
  of mAnd: c.genAndOr(n, opcFJmp, dest)
  of mOr:  c.genAndOr(n, opcTJmp, dest)
  of mUnaryLt:
    let tmp = c.genx(n.sons[1])
    if dest < 0: dest = c.getTemp(n.typ)
    c.gABI(n, opcSubImmInt, dest, tmp, 1)
    c.freeTemp(tmp)
  of mPred, mSubI:
    c.genAddSubInt(n, dest, opcSubInt)
  of mSucc, mAddI:
    c.genAddSubInt(n, dest, opcAddInt)
  of mInc, mDec:
    unused(n, dest)
    let opc = if m == mInc: opcAddInt else: opcSubInt
    let d = c.genx(n.sons[1])
    if n.sons[2].isInt8Lit:
      c.gABI(n, succ(opc), d, d, n.sons[2].intVal)
    else:
      let tmp = c.genx(n.sons[2])
      c.gABC(n, opc, d, d, tmp)
      c.freeTemp(tmp)
    c.genNarrow(n.sons[1], d)
    c.genAsgnPatch(n.sons[1], d)
    c.freeTemp(d)
  of mOrd, mChr, mArrToSeq: c.gen(n.sons[1], dest)
  of mNew, mNewFinalize:
    unused(n, dest)
    c.genNew(n)
  of mNewSeq:
    unused(n, dest)
    c.genNewSeq(n)
  of mNewString:
    genUnaryABC(c, n, dest, opcNewStr)
    # XXX buggy
  of mNewStringOfCap:
    # we ignore the 'cap' argument and translate it as 'newString(0)'.
    # eval n.sons[1] for possible side effects:
    var tmp = c.genx(n.sons[1])
    c.gABx(n, opcLdImmInt, tmp, 0)
    if dest < 0: dest = c.getTemp(n.typ)
    c.gABC(n, opcNewStr, dest, tmp)
    c.freeTemp(tmp)
    # XXX buggy
  of mLengthOpenArray, mLengthArray, mLengthSeq, mXLenSeq:
    genUnaryABI(c, n, dest, opcLenSeq)
  of mLengthStr, mXLenStr:
    genUnaryABI(c, n, dest, opcLenStr)
  of mIncl, mExcl:
    unused(n, dest)
    var d = c.genx(n.sons[1])
    var tmp = c.genx(n.sons[2])
    c.genSetType(n.sons[1], d)
    c.gABC(n, if m == mIncl: opcIncl else: opcExcl, d, tmp)
    c.freeTemp(d)
    c.freeTemp(tmp)
  of mCard: genCard(c, n, dest)
  of mMulI: genBinaryABCnarrow(c, n, dest, opcMulInt)
  of mDivI: genBinaryABCnarrow(c, n, dest, opcDivInt)
  of mModI: genBinaryABCnarrow(c, n, dest, opcModInt)
  of mAddF64: genBinaryABC(c, n, dest, opcAddFloat)
  of mSubF64: genBinaryABC(c, n, dest, opcSubFloat)
  of mMulF64: genBinaryABC(c, n, dest, opcMulFloat)
  of mDivF64: genBinaryABC(c, n, dest, opcDivFloat)
  of mShrI: genBinaryABCnarrowU(c, n, dest, opcShrInt)
  of mShlI: genBinaryABCnarrowU(c, n, dest, opcShlInt)
  of mBitandI: genBinaryABCnarrowU(c, n, dest, opcBitandInt)
  of mBitorI: genBinaryABCnarrowU(c, n, dest, opcBitorInt)
  of mBitxorI: genBinaryABCnarrowU(c, n, dest, opcBitxorInt)
  of mAddU: genBinaryABCnarrowU(c, n, dest, opcAddu)
  of mSubU: genBinaryABCnarrowU(c, n, dest, opcSubu)
  of mMulU: genBinaryABCnarrowU(c, n, dest, opcMulu)
  of mDivU: genBinaryABCnarrowU(c, n, dest, opcDivu)
  of mModU: genBinaryABCnarrowU(c, n, dest, opcModu)
  of mEqI, mEqB, mEqEnum, mEqCh:
    genBinaryABC(c, n, dest, opcEqInt)
  of mLeI, mLeEnum, mLeCh, mLeB:
    genBinaryABC(c, n, dest, opcLeInt)
  of mLtI, mLtEnum, mLtCh, mLtB:
    genBinaryABC(c, n, dest, opcLtInt)
  of mEqF64: genBinaryABC(c, n, dest, opcEqFloat)
  of mLeF64: genBinaryABC(c, n, dest, opcLeFloat)
  of mLtF64: genBinaryABC(c, n, dest, opcLtFloat)
  of mLePtr, mLeU, mLeU64: genBinaryABC(c, n, dest, opcLeu)
  of mLtPtr, mLtU, mLtU64: genBinaryABC(c, n, dest, opcLtu)
  of mEqProc, mEqRef, mEqUntracedRef, mEqCString:
    genBinaryABC(c, n, dest, opcEqRef)
  of mXor: genBinaryABCnarrowU(c, n, dest, opcXor)
  of mNot: genUnaryABC(c, n, dest, opcNot)
  of mUnaryMinusI, mUnaryMinusI64:
    genUnaryABC(c, n, dest, opcUnaryMinusInt)
    genNarrow(c, n, dest)
  of mUnaryMinusF64: genUnaryABC(c, n, dest, opcUnaryMinusFloat)
  of mUnaryPlusI, mUnaryPlusF64: gen(c, n.sons[1], dest)
  of mBitnotI:
    genUnaryABC(c, n, dest, opcBitnotInt)
    genNarrowU(c, n, dest)
  of mZe8ToI, mZe8ToI64, mZe16ToI, mZe16ToI64, mZe32ToI64, mZeIToI64,
     mToU8, mToU16, mToU32, mToFloat, mToBiggestFloat, mToInt,
     mToBiggestInt, mCharToStr, mBoolToStr, mIntToStr, mInt64ToStr,
     mFloatToStr, mCStrToStr, mStrToStr, mEnumToStr:
    genConv(c, n, n.sons[1], dest)
  of mEqStr: genBinaryABC(c, n, dest, opcEqStr)
  of mLeStr: genBinaryABC(c, n, dest, opcLeStr)
  of mLtStr: genBinaryABC(c, n, dest, opcLtStr)
  of mEqSet: genBinarySet(c, n, dest, opcEqSet)
  of mLeSet: genBinarySet(c, n, dest, opcLeSet)
  of mLtSet: genBinarySet(c, n, dest, opcLtSet)
  of mMulSet: genBinarySet(c, n, dest, opcMulSet)
  of mPlusSet: genBinarySet(c, n, dest, opcPlusSet)
  of mMinusSet: genBinarySet(c, n, dest, opcMinusSet)
  of mSymDiffSet: genBinarySet(c, n, dest, opcSymdiffSet)
  of mConStrStr: genVarargsABC(c, n, dest, opcConcatStr)
  of mInSet: genBinarySet(c, n, dest, opcContainsSet)
  of mRepr: genUnaryABC(c, n, dest, opcRepr)
  of mExit:
    unused(n, dest)
    var tmp = c.genx(n.sons[1])
    c.gABC(n, opcQuit, tmp)
    c.freeTemp(tmp)
  of mSetLengthStr, mSetLengthSeq:
    unused(n, dest)
    var d = c.genx(n.sons[1])
    var tmp = c.genx(n.sons[2])
    c.gABC(n, if m == mSetLengthStr: opcSetLenStr else: opcSetLenSeq, d, tmp)
    c.genAsgnPatch(n.sons[1], d)
    c.freeTemp(tmp)
  of mSwap:
    unused(n, dest)
    c.gen(lowerSwap(n, if c.prc == nil: c.module else: c.prc.sym))
  of mIsNil: genUnaryABC(c, n, dest, opcIsNil)
  of mCopyStr:
    if dest < 0: dest = c.getTemp(n.typ)
    var
      tmp1 = c.genx(n.sons[1])
      tmp2 = c.genx(n.sons[2])
      tmp3 = c.getTemp(n.sons[2].typ)
    c.gABC(n, opcLenStr, tmp3, tmp1)
    c.gABC(n, opcSubStr, dest, tmp1, tmp2)
    c.gABC(n, opcSubStr, tmp3)
    c.freeTemp(tmp1)
    c.freeTemp(tmp2)
    c.freeTemp(tmp3)
  of mCopyStrLast:
    if dest < 0: dest = c.getTemp(n.typ)
    var
      tmp1 = c.genx(n.sons[1])
      tmp2 = c.genx(n.sons[2])
      tmp3 = c.genx(n.sons[3])
    c.gABC(n, opcSubStr, dest, tmp1, tmp2)
    c.gABC(n, opcSubStr, tmp3)
    c.freeTemp(tmp1)
    c.freeTemp(tmp2)
    c.freeTemp(tmp3)
  of mParseBiggestFloat:
    if dest < 0: dest = c.getTemp(n.typ)
    var d2: TRegister
    # skip 'nkHiddenAddr':
    let d2AsNode = n.sons[2].sons[0]
    if needsAsgnPatch(d2AsNode):
      d2 = c.getTemp(getSysType(tyFloat))
    else:
      d2 = c.genx(d2AsNode)
    var
      tmp1 = c.genx(n.sons[1])
      tmp3 = c.genx(n.sons[3])
    c.gABC(n, opcParseFloat, dest, tmp1, d2)
    c.gABC(n, opcParseFloat, tmp3)
    c.freeTemp(tmp1)
    c.freeTemp(tmp3)
    c.genAsgnPatch(d2AsNode, d2)
    c.freeTemp(d2)
  of mReset:
    unused(n, dest)
    var d = c.genx(n.sons[1])
    c.gABC(n, opcReset, d)
  of mOf, mIs:
    if dest < 0: dest = c.getTemp(n.typ)
    var tmp = c.genx(n.sons[1])
    var idx = c.getTemp(getSysType(tyInt))
    var typ = n.sons[2].typ
    if m == mOf: typ = typ.skipTypes(abstractPtrs-{tyTypeDesc})
    c.gABx(n, opcLdImmInt, idx, c.genType(typ))
    c.gABC(n, if m == mOf: opcOf else: opcIs, dest, tmp, idx)
    c.freeTemp(tmp)
    c.freeTemp(idx)
  of mSizeOf:
    globalError(n.info, errCannotInterpretNodeX, renderTree(n))
  of mHigh:
    if dest < 0: dest = c.getTemp(n.typ)
    let tmp = c.genx(n.sons[1])
    case n.sons[1].typ.skipTypes(abstractVar-{tyTypeDesc}).kind:
    of tyString, tyCString:
      c.gABI(n, opcLenStr, dest, tmp, 1)
    else:
      c.gABI(n, opcLenSeq, dest, tmp, 1)
    c.freeTemp(tmp)
  of mEcho:
    unused(n, dest)
    let n = n[1].skipConv
    let x = c.getTempRange(n.len, slotTempUnknown)
    internalAssert n.kind == nkBracket
    for i in 0.. <n.len:
      var r: TRegister = x+i
      c.gen(n.sons[i], r)
    c.gABC(n, opcEcho, x, n.len)
    c.freeTempRange(x, n.len)
  of mAppendStrCh:
    unused(n, dest)
    genBinaryStmtVar(c, n, opcAddStrCh)
  of mAppendStrStr:
    unused(n, dest)
    genBinaryStmtVar(c, n, opcAddStrStr)
  of mAppendSeqElem:
    unused(n, dest)
    genBinaryStmtVar(c, n, opcAddSeqElem)
  of mParseExprToAst:
    genUnaryABC(c, n, dest, opcParseExprToAst)
  of mParseStmtToAst:
    genUnaryABC(c, n, dest, opcParseStmtToAst)
  of mTypeTrait:
    let tmp = c.genx(n.sons[1])
    if dest < 0: dest = c.getTemp(n.typ)
    c.gABx(n, opcSetType, tmp, c.genType(n.sons[1].typ))
    c.gABC(n, opcTypeTrait, dest, tmp)
    c.freeTemp(tmp)
  of mSlurp: genUnaryABC(c, n, dest, opcSlurp)
  of mStaticExec: genBinaryABCD(c, n, dest, opcGorge)
  of mNLen: genUnaryABI(c, n, dest, opcLenSeq)
  of mGetImpl: genUnaryABC(c, n, dest, opcGetImpl)
  of mNChild: genBinaryABC(c, n, dest, opcNChild)
  of mNSetChild, mNDel:
    unused(n, dest)
    var
      tmp1 = c.genx(n.sons[1])
      tmp2 = c.genx(n.sons[2])
      tmp3 = c.genx(n.sons[3])
    c.gABC(n, if m == mNSetChild: opcNSetChild else: opcNDel, tmp1, tmp2, tmp3)
    c.freeTemp(tmp1)
    c.freeTemp(tmp2)
    c.freeTemp(tmp3)
  of mNAdd: genBinaryABC(c, n, dest, opcNAdd)
  of mNAddMultiple: genBinaryABC(c, n, dest, opcNAddMultiple)
  of mNKind: genUnaryABC(c, n, dest, opcNKind)
  of mNIntVal: genUnaryABC(c, n, dest, opcNIntVal)
  of mNFloatVal: genUnaryABC(c, n, dest, opcNFloatVal)
  of mNSymbol: genUnaryABC(c, n, dest, opcNSymbol)
  of mNIdent: genUnaryABC(c, n, dest, opcNIdent)
  of mNGetType:
    let tmp = c.genx(n.sons[1])
    if dest < 0: dest = c.getTemp(n.typ)
    c.gABC(n, opcNGetType, dest, tmp, if n[0].sym.name.s == "typeKind": 1 else: 0)
    c.freeTemp(tmp)
    #genUnaryABC(c, n, dest, opcNGetType)
  of mNStrVal: genUnaryABC(c, n, dest, opcNStrVal)
  of mNSetIntVal:
    unused(n, dest)
    genBinaryStmt(c, n, opcNSetIntVal)
  of mNSetFloatVal:
    unused(n, dest)
    genBinaryStmt(c, n, opcNSetFloatVal)
  of mNSetSymbol:
    unused(n, dest)
    genBinaryStmt(c, n, opcNSetSymbol)
  of mNSetIdent:
    unused(n, dest)
    genBinaryStmt(c, n, opcNSetIdent)
  of mNSetType:
    unused(n, dest)
    genBinaryStmt(c, n, opcNSetType)
  of mNSetStrVal:
    unused(n, dest)
    genBinaryStmt(c, n, opcNSetStrVal)
  of mNNewNimNode: genBinaryABC(c, n, dest, opcNNewNimNode)
  of mNCopyNimNode: genUnaryABC(c, n, dest, opcNCopyNimNode)
  of mNCopyNimTree: genUnaryABC(c, n, dest, opcNCopyNimTree)
  of mNBindSym:
    if n[1].kind in {nkClosedSymChoice, nkOpenSymChoice, nkSym}:
      let idx = c.genLiteral(n[1])
      if dest < 0: dest = c.getTemp(n.typ)
      c.gABx(n, opcNBindSym, dest, idx)
    else:
      localError(n.info, "invalid bindSym usage")
  of mStrToIdent: genUnaryABC(c, n, dest, opcStrToIdent)
  of mIdentToStr: genUnaryABC(c, n, dest, opcIdentToStr)
  of mEqIdent: genBinaryABC(c, n, dest, opcEqIdent)
  of mEqNimrodNode: genBinaryABC(c, n, dest, opcEqNimrodNode)
  of mSameNodeType: genBinaryABC(c, n, dest, opcSameNodeType)
  of mNLineInfo: genUnaryABC(c, n, dest, opcNLineInfo)
  of mNHint:
    unused(n, dest)
    genUnaryStmt(c, n, opcNHint)
  of mNWarning:
    unused(n, dest)
    genUnaryStmt(c, n, opcNWarning)
  of mNError:
    if n.len <= 1:
      # query error condition:
      c.gABC(n, opcQueryErrorFlag, dest)
    else:
      # setter
      unused(n, dest)
      genUnaryStmt(c, n, opcNError)
  of mNCallSite:
    if dest < 0: dest = c.getTemp(n.typ)
    c.gABC(n, opcCallSite, dest)
  of mNGenSym: genBinaryABC(c, n, dest, opcGenSym)
  of mMinI, mMaxI, mAbsF64, mMinF64, mMaxF64, mAbsI,
     mDotDot:
    c.genCall(n, dest)
  of mExpandToAst:
    if n.len != 2:
      globalError(n.info, errGenerated, "expandToAst requires 1 argument")
    let arg = n.sons[1]
    if arg.kind in nkCallKinds:
      #if arg[0].kind != nkSym or arg[0].sym.kind notin {skTemplate, skMacro}:
      #      "ExpandToAst: expanded symbol is no macro or template"
      if dest < 0: dest = c.getTemp(n.typ)
      c.genCall(arg, dest)
      # do not call clearDest(n, dest) here as getAst has a meta-type as such
      # produces a value
    else:
      globalError(n.info, "expandToAst requires a call expression")
  else:
    # mGCref, mGCunref,
    globalError(n.info, "cannot generate code for: " & $m)

proc genMarshalLoad(c: PCtx, n: PNode, dest: var TDest) =
  ## Signature: proc to*[T](data: string): T
  if dest < 0: dest = c.getTemp(n.typ)
  var tmp = c.genx(n.sons[1])
  c.gABC(n, opcMarshalLoad, dest, tmp)
  c.gABx(n, opcMarshalLoad, 0, c.genType(n.typ))
  c.freeTemp(tmp)

proc genMarshalStore(c: PCtx, n: PNode, dest: var TDest) =
  ## Signature: proc `$$`*[T](x: T): string
  if dest < 0: dest = c.getTemp(n.typ)
  var tmp = c.genx(n.sons[1])
  c.gABC(n, opcMarshalStore, dest, tmp)
  c.gABx(n, opcMarshalStore, 0, c.genType(n.sons[1].typ))
  c.freeTemp(tmp)

const
  atomicTypes = {tyBool, tyChar,
    tyExpr, tyStmt, tyTypeDesc, tyStatic,
    tyEnum,
    tyOrdinal,
    tyRange,
    tyProc,
    tyPointer, tyOpenArray,
    tyString, tyCString,
    tyInt, tyInt8, tyInt16, tyInt32, tyInt64,
    tyFloat, tyFloat32, tyFloat64, tyFloat128,
    tyUInt, tyUInt8, tyUInt16, tyUInt32, tyUInt64}

proc fitsRegister*(t: PType): bool =
  assert t != nil
  t.skipTypes(abstractInst-{tyTypeDesc}).kind in {
    tyRange, tyEnum, tyBool, tyInt..tyUInt64, tyChar}

proc requiresCopy(n: PNode): bool =
  if n.typ.skipTypes(abstractInst-{tyTypeDesc}).kind in atomicTypes:
    result = false
  elif n.kind in ({nkCurly, nkBracket, nkPar, nkObjConstr}+nkCallKinds):
    result = false
  else:
    result = true

proc unneededIndirection(n: PNode): bool =
  n.typ.skipTypes(abstractInst-{tyTypeDesc}).kind == tyRef

proc canElimAddr(n: PNode): PNode =
  case n.sons[0].kind
  of nkObjUpConv, nkObjDownConv, nkChckRange, nkChckRangeF, nkChckRange64:
    var m = n.sons[0].sons[0]
    if m.kind in {nkDerefExpr, nkHiddenDeref}:
      # addr ( nkConv ( deref ( x ) ) ) --> nkConv(x)
      result = copyNode(n.sons[0])
      result.add m.sons[0]
  of nkHiddenStdConv, nkHiddenSubConv, nkConv:
    var m = n.sons[0].sons[1]
    if m.kind in {nkDerefExpr, nkHiddenDeref}:
      # addr ( nkConv ( deref ( x ) ) ) --> nkConv(x)
      result = copyNode(n.sons[0])
      result.add m.sons[0]
  else:
    if n.sons[0].kind in {nkDerefExpr, nkHiddenDeref}:
      # addr ( deref ( x )) --> x
      result = n.sons[0].sons[0]

proc genAddrDeref(c: PCtx; n: PNode; dest: var TDest; opc: TOpcode;
                  flags: TGenFlags) =
  # a nop for certain types
  let isAddr = opc in {opcAddrNode, opcAddrReg}
  if isAddr and (let m = canElimAddr(n); m != nil):
    gen(c, m, dest, flags)
    return
  let newflags = if isAddr: flags+{gfAddrOf} else: flags
  # consider:
  # proc foo(f: var ref int) =
  #   f = new(int)
  # proc blah() =
  #   var x: ref int
  #   foo x
  #
  # The type of 'f' is 'var ref int' and of 'x' is 'ref int'. Hence for
  # nkAddr we must not use 'unneededIndirection', but for deref we use it.
  if not isAddr and unneededIndirection(n.sons[0]):
    gen(c, n.sons[0], dest, newflags)
    if gfAddrOf notin flags and fitsRegister(n.typ):
      c.gABC(n, opcNodeToReg, dest, dest)
  elif isAddr and isGlobal(n.sons[0]):
    gen(c, n.sons[0], dest, flags+{gfAddrOf})
  else:
    let tmp = c.genx(n.sons[0], newflags)
    if dest < 0: dest = c.getTemp(n.typ)
    if not isAddr:
      gABC(c, n, opc, dest, tmp)
      assert n.typ != nil
      if gfAddrOf notin flags and fitsRegister(n.typ):
        c.gABC(n, opcNodeToReg, dest, dest)
    elif c.prc.slots[tmp].kind >= slotTempUnknown:
      gABC(c, n, opcAddrNode, dest, tmp)
      # hack ahead; in order to fix bug #1781 we mark the temporary as
      # permanent, so that it's not used for anything else:
      c.prc.slots[tmp].kind = slotTempPerm
      # XXX this is still a hack
      #message(n.info, warnUser, "suspicious opcode used")
    else:
      gABC(c, n, opcAddrReg, dest, tmp)
    c.freeTemp(tmp)

proc whichAsgnOpc(n: PNode): TOpcode =
  case n.typ.skipTypes(abstractRange-{tyTypeDesc}).kind
  of tyBool, tyChar, tyEnum, tyOrdinal, tyInt..tyInt64, tyUInt..tyUInt64:
    opcAsgnInt
  of tyString, tyCString:
    opcAsgnStr
  of tyFloat..tyFloat128:
    opcAsgnFloat
  of tyRef, tyNil, tyVar:
    opcAsgnRef
  else:
    opcAsgnComplex

proc isRef(t: PType): bool = t.skipTypes(abstractRange-{tyTypeDesc}).kind == tyRef

proc whichAsgnOpc(n: PNode; opc: TOpcode): TOpcode = opc

proc genAsgn(c: PCtx; dest: TDest; ri: PNode; requiresCopy: bool) =
  let tmp = c.genx(ri)
  assert dest >= 0
  gABC(c, ri, whichAsgnOpc(ri), dest, tmp, 1-ord(requiresCopy))
  c.freeTemp(tmp)

proc setSlot(c: PCtx; v: PSym) =
  # XXX generate type initialization here?
  if v.position == 0:
    if c.prc.maxSlots == 0: c.prc.maxSlots = 1
    if c.prc.maxSlots >= high(TRegister):
      globalError(v.info, "cannot generate code; too many registers required")
    v.position = c.prc.maxSlots
    c.prc.slots[v.position] = (inUse: true,
        kind: if v.kind == skLet: slotFixedLet else: slotFixedVar)
    inc c.prc.maxSlots

proc cannotEval(n: PNode) {.noinline.} =
  globalError(n.info, errGenerated, "cannot evaluate at compile time: " &
    n.renderTree)

proc isOwnedBy(a, b: PSym): bool =
  var a = a.owner
  while a != nil and a.kind != skModule:
    if a == b: return true
    a = a.owner

proc getOwner(c: PCtx): PSym =
  result = c.prc.sym
  if result.isNil: result = c.module

proc checkCanEval(c: PCtx; n: PNode) =
  # we need to ensure that we don't evaluate 'x' here:
  # proc foo() = var x ...
  let s = n.sym
  if {sfCompileTime, sfGlobal} <= s.flags: return
  if s.kind in {skVar, skTemp, skLet, skParam, skResult} and
      not s.isOwnedBy(c.prc.sym) and s.owner != c.module and c.mode != emRepl:
    cannotEval(n)
  elif s.kind in {skProc, skConverter, skMethod,
                  skIterator, skClosureIterator} and sfForward in s.flags:
    cannotEval(n)

proc isTemp(c: PCtx; dest: TDest): bool =
  result = dest >= 0 and c.prc.slots[dest].kind >= slotTempUnknown

template needsAdditionalCopy(n): expr =
  not c.isTemp(dest) and not fitsRegister(n.typ)

proc skipDeref(n: PNode): PNode =
  result = if n.kind in {nkDerefExpr, nkHiddenDeref}: n.sons[0] else: n

proc preventFalseAlias(c: PCtx; n: PNode; opc: TOpcode;
                       dest, idx, value: TRegister) =
  # opcLdObj et al really means "load address". We sometimes have to create a
  # copy in order to not introduce false aliasing:
  # mylocal = a.b  # needs a copy of the data!
  assert n.typ != nil
  if needsAdditionalCopy(n):
    var cc = c.getTemp(n.typ)
    c.gABC(n, whichAsgnOpc(n), cc, value, 0)
    c.gABC(n, opc, dest, idx, cc)
    c.freeTemp(cc)
  else:
    c.gABC(n, opc, dest, idx, value)

proc genAsgn(c: PCtx; le, ri: PNode; requiresCopy: bool) =
  case le.kind
  of nkBracketExpr:
    let dest = c.genx(le.sons[0], {gfAddrOf, gfFieldAccess})
    let idx = c.genIndex(le.sons[1], le.sons[0].typ)
    let tmp = c.genx(ri)
    if le.sons[0].typ.skipTypes(abstractVarRange-{tyTypeDesc}).kind in {
        tyString, tyCString}:
      c.preventFalseAlias(le, opcWrStrIdx, dest, idx, tmp)
    else:
      c.preventFalseAlias(le, opcWrArr, dest, idx, tmp)
    c.freeTemp(tmp)
  of nkDotExpr, nkCheckedFieldExpr:
    # XXX field checks here
    let left = if le.kind == nkDotExpr: le else: le.sons[0]
    let dest = c.genx(left.sons[0], {gfAddrOf, gfFieldAccess})
    let idx = genField(left.sons[1])
    let tmp = c.genx(ri)
    c.preventFalseAlias(left, opcWrObj, dest, idx, tmp)
    c.freeTemp(tmp)
  of nkDerefExpr, nkHiddenDeref:
    let dest = c.genx(le.sons[0], {gfAddrOf})
    let tmp = c.genx(ri)
    c.preventFalseAlias(le, opcWrDeref, dest, 0, tmp)
    c.freeTemp(tmp)
  of nkSym:
    let s = le.sym
    checkCanEval(c, le)
    if s.isGlobal:
      withTemp(tmp, le.typ):
        c.gen(le, tmp, {gfAddrOf})
        let val = c.genx(ri)
        c.preventFalseAlias(le, opcWrDeref, tmp, 0, val)
        c.freeTemp(val)
    else:
      if s.kind == skForVar: c.setSlot s
      internalAssert s.position > 0 or (s.position == 0 and
                                        s.kind in {skParam,skResult})
      var dest: TRegister = s.position + ord(s.kind == skParam)
      assert le.typ != nil
      if needsAdditionalCopy(le) and s.kind in {skResult, skVar, skParam}:
        var cc = c.getTemp(le.typ)
        gen(c, ri, cc)
        c.gABC(le, whichAsgnOpc(le), dest, cc, 1)
        c.freeTemp(cc)
      else:
        gen(c, ri, dest)
  else:
    let dest = c.genx(le, {gfAddrOf})
    genAsgn(c, dest, ri, requiresCopy)

proc genLit(c: PCtx; n: PNode; dest: var TDest) =
  # opcLdConst is now always valid. We produce the necessary copy in the
  # assignments now:
  #var opc = opcLdConst
  if dest < 0: dest = c.getTemp(n.typ)
  #elif c.prc.slots[dest].kind == slotFixedVar: opc = opcAsgnConst
  let lit = genLiteral(c, n)
  c.gABx(n, opcLdConst, dest, lit)

proc genTypeLit(c: PCtx; t: PType; dest: var TDest) =
  var n = newNode(nkType)
  n.typ = t
  genLit(c, n, dest)

proc importcSym(c: PCtx; info: TLineInfo; s: PSym) =
  when hasFFI:
    if allowFFI in c.features:
      c.globals.add(importcSymbol(s))
      s.position = c.globals.len
    else:
      localError(info, errGenerated, "VM is not allowed to 'importc'")
  else:
    localError(info, errGenerated,
               "cannot 'importc' variable at compile time")

proc getNullValue*(typ: PType, info: TLineInfo): PNode

proc genGlobalInit(c: PCtx; n: PNode; s: PSym) =
  c.globals.add(getNullValue(s.typ, n.info))
  s.position = c.globals.len
  # This is rather hard to support, due to the laziness of the VM code
  # generator. See tests/compile/tmacro2 for why this is necessary:
  #   var decls{.compileTime.}: seq[NimNode] = @[]
  let dest = c.getTemp(s.typ)
  c.gABx(n, opcLdGlobal, dest, s.position)
  let tmp = c.genx(s.ast)
  c.preventFalseAlias(n, opcWrDeref, dest, 0, tmp)
  c.freeTemp(dest)
  c.freeTemp(tmp)

proc genRdVar(c: PCtx; n: PNode; dest: var TDest; flags: TGenFlags) =
  let s = n.sym
  if s.isGlobal:
    if sfCompileTime in s.flags or c.mode == emRepl:
      discard
    elif s.position == 0:
      cannotEval(n)
    if s.position == 0:
      if sfImportc in s.flags: c.importcSym(n.info, s)
      else: genGlobalInit(c, n, s)
    if dest < 0: dest = c.getTemp(n.typ)
    assert s.typ != nil
    if gfAddrOf notin flags and fitsRegister(s.typ):
      var cc = c.getTemp(n.typ)
      c.gABx(n, opcLdGlobal, cc, s.position)
      c.gABC(n, opcNodeToReg, dest, cc)
      c.freeTemp(cc)
    elif {gfAddrOf, gfFieldAccess} * flags == {gfAddrOf}:
      c.gABx(n, opcLdGlobalAddr, dest, s.position)
    else:
      c.gABx(n, opcLdGlobal, dest, s.position)
  else:
    if s.kind == skForVar and c.mode == emRepl: c.setSlot(s)
    if s.position > 0 or (s.position == 0 and
                          s.kind in {skParam,skResult}):
      if dest < 0:
        dest = s.position + ord(s.kind == skParam)
        internalAssert(c.prc.slots[dest].kind < slotSomeTemp)
      else:
        # we need to generate an assignment:
        genAsgn(c, dest, n, c.prc.slots[dest].kind >= slotSomeTemp)
    else:
      # see tests/t99bott for an example that triggers it:
      cannotEval(n)

template needsRegLoad(): expr =
  gfAddrOf notin flags and fitsRegister(n.typ.skipTypes({tyVar}))

proc genArrAccess2(c: PCtx; n: PNode; dest: var TDest; opc: TOpcode;
                   flags: TGenFlags) =
  let a = c.genx(n.sons[0], flags)
  let b = c.genIndex(n.sons[1], n.sons[0].typ)
  if dest < 0: dest = c.getTemp(n.typ)
  if needsRegLoad():
    var cc = c.getTemp(n.typ)
    c.gABC(n, opc, cc, a, b)
    c.gABC(n, opcNodeToReg, dest, cc)
    c.freeTemp(cc)
  else:
    #message(n.info, warnUser, "argh")
    #echo "FLAGS ", flags, " ", fitsRegister(n.typ), " ", typeToString(n.typ)
    c.gABC(n, opc, dest, a, b)
  c.freeTemp(a)
  c.freeTemp(b)

proc genObjAccess(c: PCtx; n: PNode; dest: var TDest; flags: TGenFlags) =
  let a = c.genx(n.sons[0], flags)
  let b = genField(n.sons[1])
  if dest < 0: dest = c.getTemp(n.typ)
  if needsRegLoad():
    var cc = c.getTemp(n.typ)
    c.gABC(n, opcLdObj, cc, a, b)
    c.gABC(n, opcNodeToReg, dest, cc)
    c.freeTemp(cc)
  else:
    c.gABC(n, opcLdObj, dest, a, b)
  c.freeTemp(a)

proc genCheckedObjAccess(c: PCtx; n: PNode; dest: var TDest; flags: TGenFlags) =
  # XXX implement field checks!
  genObjAccess(c, n.sons[0], dest, flags)

proc genArrAccess(c: PCtx; n: PNode; dest: var TDest; flags: TGenFlags) =
  let arrayType = n.sons[0].typ.skipTypes(abstractVarRange-{tyTypeDesc}).kind
  if arrayType in {tyString, tyCString}:
    genArrAccess2(c, n, dest, opcLdStrIdx, {})
  elif arrayType == tyTypeDesc:
    c.genTypeLit(n.typ, dest)
  else:
    genArrAccess2(c, n, dest, opcLdArr, flags)

proc getNullValueAux(obj: PNode, result: PNode) =
  case obj.kind
  of nkRecList:
    for i in countup(0, sonsLen(obj) - 1): getNullValueAux(obj.sons[i], result)
  of nkRecCase:
    getNullValueAux(obj.sons[0], result)
    for i in countup(1, sonsLen(obj) - 1):
      getNullValueAux(lastSon(obj.sons[i]), result)
  of nkSym:
    let field = newNodeI(nkExprColonExpr, result.info)
    field.add(obj)
    field.add(getNullValue(obj.sym.typ, result.info))
    addSon(result, field)
  else: globalError(result.info, "cannot create null element for: " & $obj)

proc getNullValue(typ: PType, info: TLineInfo): PNode =
  var t = skipTypes(typ, abstractRange-{tyTypeDesc})
  result = emptyNode
  case t.kind
  of tyBool, tyEnum, tyChar, tyInt..tyInt64:
    result = newNodeIT(nkIntLit, info, t)
  of tyUInt..tyUInt64:
    result = newNodeIT(nkUIntLit, info, t)
  of tyFloat..tyFloat128:
    result = newNodeIT(nkFloatLit, info, t)
  of tyCString, tyString:
    result = newNodeIT(nkStrLit, info, t)
  of tyVar, tyPointer, tyPtr, tySequence, tyExpr,
     tyStmt, tyTypeDesc, tyStatic, tyRef, tyNil:
    result = newNodeIT(nkNilLit, info, t)
  of tyProc:
    if t.callConv != ccClosure:
      result = newNodeIT(nkNilLit, info, t)
    else:
      result = newNodeIT(nkPar, info, t)
      result.add(newNodeIT(nkNilLit, info, t))
      result.add(newNodeIT(nkNilLit, info, t))
  of tyObject:
    result = newNodeIT(nkObjConstr, info, t)
    result.add(newNodeIT(nkEmpty, info, t))
    getNullValueAux(t.n, result)
    # initialize inherited fields:
    var base = t.sons[0]
    while base != nil:
      getNullValueAux(skipTypes(base, skipPtrs).n, result)
      base = base.sons[0]
  of tyArray, tyArrayConstr:
    result = newNodeIT(nkBracket, info, t)
    for i in countup(0, int(lengthOrd(t)) - 1):
      addSon(result, getNullValue(elemType(t), info))
  of tyTuple:
    result = newNodeIT(nkPar, info, t)
    for i in countup(0, sonsLen(t) - 1):
      addSon(result, getNullValue(t.sons[i], info))
  of tySet:
    result = newNodeIT(nkCurly, info, t)
  else:
    globalError(info, "cannot create null element for: " & $t.kind)

proc ldNullOpcode(t: PType): TOpcode =
  assert t != nil
  if fitsRegister(t): opcLdNullReg else: opcLdNull

proc genVarSection(c: PCtx; n: PNode) =
  for a in n:
    if a.kind == nkCommentStmt: continue
    #assert(a.sons[0].kind == nkSym) can happen for transformed vars
    if a.kind == nkVarTuple:
      for i in 0 .. a.len-3:
        setSlot(c, a[i].sym)
        checkCanEval(c, a[i])
      c.gen(lowerTupleUnpacking(a, c.getOwner))
    elif a.sons[0].kind == nkSym:
      let s = a.sons[0].sym
      checkCanEval(c, a.sons[0])
      if s.isGlobal:
        if s.position == 0:
          if sfImportc in s.flags: c.importcSym(a.info, s)
          else:
            let sa = getNullValue(s.typ, a.info)
            #if s.ast.isNil: getNullValue(s.typ, a.info)
            #else: canonValue(s.ast)
            assert sa.kind != nkCall
            c.globals.add(sa)
            s.position = c.globals.len
        if a.sons[2].kind != nkEmpty:
          let tmp = c.genx(a.sons[0], {gfAddrOf})
          let val = c.genx(a.sons[2])
          c.preventFalseAlias(a.sons[2], opcWrDeref, tmp, 0, val)
          c.freeTemp(val)
          c.freeTemp(tmp)
      else:
        setSlot(c, s)
        if a.sons[2].kind == nkEmpty:
          c.gABx(a, ldNullOpcode(s.typ), s.position, c.genType(s.typ))
        else:
          assert s.typ != nil
          if not fitsRegister(s.typ):
            c.gABx(a, ldNullOpcode(s.typ), s.position, c.genType(s.typ))
          let le = a.sons[0]
          assert le.typ != nil
          if not fitsRegister(le.typ) and s.kind in {skResult, skVar, skParam}:
            var cc = c.getTemp(le.typ)
            gen(c, a.sons[2], cc)
            c.gABC(le, whichAsgnOpc(le), s.position.TRegister, cc, 1)
            c.freeTemp(cc)
          else:
            gen(c, a.sons[2], s.position.TRegister)
    else:
      # assign to a.sons[0]; happens for closures
      if a.sons[2].kind == nkEmpty:
        let tmp = genx(c, a.sons[0])
        c.gABx(a, ldNullOpcode(a[0].typ), tmp, c.genType(a.sons[0].typ))
        c.freeTemp(tmp)
      else:
        genAsgn(c, a.sons[0], a.sons[2], true)

proc genArrayConstr(c: PCtx, n: PNode, dest: var TDest) =
  if dest < 0: dest = c.getTemp(n.typ)
  c.gABx(n, opcLdNull, dest, c.genType(n.typ))

  let intType = getSysType(tyInt)
  let seqType = n.typ.skipTypes(abstractVar-{tyTypeDesc})
  if seqType.kind == tySequence:
    var tmp = c.getTemp(intType)
    c.gABx(n, opcLdImmInt, tmp, n.len)
    c.gABx(n, opcNewSeq, dest, c.genType(seqType))
    c.gABx(n, opcNewSeq, tmp, 0)
    c.freeTemp(tmp)

  if n.len > 0:
    var tmp = getTemp(c, intType)
    c.gABx(n, opcLdNullReg, tmp, c.genType(intType))
    for x in n:
      let a = c.genx(x)
      c.preventFalseAlias(n, whichAsgnOpc(x, opcWrArr), dest, tmp, a)
      c.gABI(n, opcAddImmInt, tmp, tmp, 1)
      c.freeTemp(a)
    c.freeTemp(tmp)

proc genSetConstr(c: PCtx, n: PNode, dest: var TDest) =
  if dest < 0: dest = c.getTemp(n.typ)
  c.gABx(n, opcLdNull, dest, c.genType(n.typ))
  for x in n:
    if x.kind == nkRange:
      let a = c.genx(x.sons[0])
      let b = c.genx(x.sons[1])
      c.gABC(n, opcInclRange, dest, a, b)
      c.freeTemp(b)
      c.freeTemp(a)
    else:
      let a = c.genx(x)
      c.gABC(n, opcIncl, dest, a)
      c.freeTemp(a)

proc genObjConstr(c: PCtx, n: PNode, dest: var TDest) =
  if dest < 0: dest = c.getTemp(n.typ)
  let t = n.typ.skipTypes(abstractRange-{tyTypeDesc})
  if t.kind == tyRef:
    c.gABx(n, opcNew, dest, c.genType(t.sons[0]))
  else:
    c.gABx(n, opcLdNull, dest, c.genType(n.typ))
  for i in 1.. <n.len:
    let it = n.sons[i]
    if it.kind == nkExprColonExpr and it.sons[0].kind == nkSym:
      let idx = genField(it.sons[0])
      let tmp = c.genx(it.sons[1])
      c.preventFalseAlias(it.sons[1], whichAsgnOpc(it.sons[1], opcWrObj),
                          dest, idx, tmp)
      c.freeTemp(tmp)
    else:
      globalError(n.info, "invalid object constructor")

proc genTupleConstr(c: PCtx, n: PNode, dest: var TDest) =
  if dest < 0: dest = c.getTemp(n.typ)
  c.gABx(n, opcLdNull, dest, c.genType(n.typ))
  # XXX x = (x.old, 22)  produces wrong code ... stupid self assignments
  for i in 0.. <n.len:
    let it = n.sons[i]
    if it.kind == nkExprColonExpr:
      let idx = genField(it.sons[0])
      let tmp = c.genx(it.sons[1])
      c.preventFalseAlias(it.sons[1], whichAsgnOpc(it.sons[1], opcWrObj),
                          dest, idx, tmp)
      c.freeTemp(tmp)
    else:
      let tmp = c.genx(it)
      c.preventFalseAlias(it, whichAsgnOpc(it, opcWrObj), dest, i.TRegister, tmp)
      c.freeTemp(tmp)

proc genProc*(c: PCtx; s: PSym): int

proc matches(s: PSym; x: string): bool =
  let y = x.split('.')
  var s = s
  var L = y.len-1
  while L >= 0:
    if s == nil or y[L].cmpIgnoreStyle(s.name.s) != 0: return false
    s = s.owner
    dec L
  result = true

proc matches(s: PSym; y: varargs[string]): bool =
  var s = s
  var L = y.len-1
  while L >= 0:
    if s == nil or y[L].cmpIgnoreStyle(s.name.s) != 0: return false
    s = if sfFromGeneric in s.flags: s.owner.owner else: s.owner
    dec L
  result = true

proc procIsCallback(c: PCtx; s: PSym): bool =
  if s.offset < -1: return true
  var i = -2
  for key, value in items(c.callbacks):
    if s.matches(key):
      doAssert s.offset == -1
      s.offset = i
      return true
    dec i

proc gen(c: PCtx; n: PNode; dest: var TDest; flags: TGenFlags = {}) =
  case n.kind
  of nkSym:
    let s = n.sym
    checkCanEval(c, n)
    case s.kind
    of skVar, skForVar, skTemp, skLet, skParam, skResult:
      genRdVar(c, n, dest, flags)
    of skProc, skConverter, skMacro, skTemplate, skMethod, skIterators:
      # 'skTemplate' is only allowed for 'getAst' support:
      if procIsCallback(c, s): discard
      elif sfImportc in s.flags: c.importcSym(n.info, s)
      genLit(c, n, dest)
    of skConst:
      gen(c, s.ast, dest)
    of skEnumField:
      if dest < 0: dest = c.getTemp(n.typ)
      if s.position >= low(int16) and s.position <= high(int16):
        c.gABx(n, opcLdImmInt, dest, s.position)
      else:
        var lit = genLiteral(c, newIntNode(nkIntLit, s.position))
        c.gABx(n, opcLdConst, dest, lit)
    of skType:
      genTypeLit(c, s.typ, dest)
    of skGenericParam:
      if c.prc.sym.kind == skMacro:
        genRdVar(c, n, dest, flags)
      else:
        internalError(n.info, "cannot generate code for: " & s.name.s)
    else:
      globalError(n.info, errGenerated, "cannot generate code for: " & s.name.s)
  of nkCallKinds:
    if n.sons[0].kind == nkSym:
      let s = n.sons[0].sym
      if s.magic != mNone:
        genMagic(c, n, dest, s.magic)
      elif matches(s, "stdlib", "marshal", "to"):
        genMarshalLoad(c, n, dest)
      elif matches(s, "stdlib", "marshal", "$$"):
        genMarshalStore(c, n, dest)
      else:
        genCall(c, n, dest)
        clearDest(c, n, dest)
    else:
      genCall(c, n, dest)
      clearDest(c, n, dest)
  of nkCharLit..nkInt64Lit:
    if isInt16Lit(n):
      if dest < 0: dest = c.getTemp(n.typ)
      c.gABx(n, opcLdImmInt, dest, n.intVal.int)
    else:
      genLit(c, n, dest)
  of nkUIntLit..pred(nkNilLit): genLit(c, n, dest)
  of nkNilLit:
    if not n.typ.isEmptyType: genLit(c, getNullValue(n.typ, n.info), dest)
    else: unused(n, dest)
  of nkAsgn, nkFastAsgn:
    unused(n, dest)
    genAsgn(c, n.sons[0], n.sons[1], n.kind == nkAsgn)
  of nkDotExpr: genObjAccess(c, n, dest, flags)
  of nkCheckedFieldExpr: genCheckedObjAccess(c, n, dest, flags)
  of nkBracketExpr: genArrAccess(c, n, dest, flags)
  of nkDerefExpr, nkHiddenDeref: genAddrDeref(c, n, dest, opcLdDeref, flags)
  of nkAddr, nkHiddenAddr: genAddrDeref(c, n, dest, opcAddrNode, flags)
  of nkIfStmt, nkIfExpr: genIf(c, n, dest)
  of nkWhenStmt:
      # This is "when nimvm" node. Chose the first branch.
      gen(c, n.sons[0].sons[1], dest)
  of nkCaseStmt: genCase(c, n, dest)
  of nkWhileStmt:
    unused(n, dest)
    genWhile(c, n)
  of nkBlockExpr, nkBlockStmt: genBlock(c, n, dest)
  of nkReturnStmt:
    unused(n, dest)
    genReturn(c, n)
  of nkRaiseStmt:
    unused(n, dest)
    genRaise(c, n)
  of nkBreakStmt:
    unused(n, dest)
    genBreak(c, n)
  of nkTryStmt: genTry(c, n, dest)
  of nkStmtList:
    #unused(n, dest)
    # XXX Fix this bug properly, lexim triggers it
    for x in n: gen(c, x)
  of nkStmtListExpr:
    let L = n.len-1
    for i in 0 .. <L: gen(c, n.sons[i])
    gen(c, n.sons[L], dest, flags)
  of nkPragmaBlock:
    gen(c, n.lastSon, dest, flags)
  of nkDiscardStmt:
    unused(n, dest)
    gen(c, n.sons[0])
  of nkHiddenStdConv, nkHiddenSubConv, nkConv:
    genConv(c, n, n.sons[1], dest)
  of nkObjDownConv:
    genConv(c, n, n.sons[0], dest)
  of nkVarSection, nkLetSection:
    unused(n, dest)
    genVarSection(c, n)
  of declarativeDefs:
    unused(n, dest)
  of nkLambdaKinds:
    let s = n.sons[namePos].sym
    discard genProc(c, s)
    genLit(c, n.sons[namePos], dest)
  of nkChckRangeF, nkChckRange64, nkChckRange:
    let
      tmp0 = c.genx(n.sons[0])
      tmp1 = c.genx(n.sons[1])
      tmp2 = c.genx(n.sons[2])
    c.gABC(n, opcRangeChck, tmp0, tmp1, tmp2)
    c.freeTemp(tmp1)
    c.freeTemp(tmp2)
    if dest >= 0:
      gABC(c, n, whichAsgnOpc(n), dest, tmp0, 1)
      c.freeTemp(tmp0)
    else:
      dest = tmp0
  of nkEmpty, nkCommentStmt, nkTypeSection, nkConstSection, nkPragma,
     nkTemplateDef, nkIncludeStmt, nkImportStmt, nkFromStmt:
    unused(n, dest)
  of nkStringToCString, nkCStringToString:
    gen(c, n.sons[0], dest)
  of nkBracket: genArrayConstr(c, n, dest)
  of nkCurly: genSetConstr(c, n, dest)
  of nkObjConstr: genObjConstr(c, n, dest)
  of nkPar, nkClosure: genTupleConstr(c, n, dest)
  of nkCast:
    if allowCast in c.features:
      genConv(c, n, n.sons[1], dest, opcCast)
    else:
      globalError(n.info, errGenerated, "VM is not allowed to 'cast'")
  else:
    globalError(n.info, errGenerated, "cannot generate VM code for " & $n)

proc removeLastEof(c: PCtx) =
  let last = c.code.len-1
  if last >= 0 and c.code[last].opcode == opcEof:
    # overwrite last EOF:
    assert c.code.len == c.debug.len
    c.code.setLen(last)
    c.debug.setLen(last)

proc genStmt*(c: PCtx; n: PNode): int =
  c.removeLastEof
  result = c.code.len
  var d: TDest = -1
  c.gen(n, d)
  c.gABC(n, opcEof)
  if d >= 0:
    globalError(n.info, errGenerated, "VM problem: dest register is set")

proc genExpr*(c: PCtx; n: PNode, requiresValue = true): int =
  c.removeLastEof
  result = c.code.len
  var d: TDest = -1
  c.gen(n, d)
  if d < 0:
    if requiresValue:
      globalError(n.info, errGenerated, "VM problem: dest register is not set")
    d = 0
  c.gABC(n, opcEof, d)

  #echo renderTree(n)
  #c.echoCode(result)

proc genParams(c: PCtx; params: PNode) =
  # res.sym.position is already 0
  c.prc.slots[0] = (inUse: true, kind: slotFixedVar)
  for i in 1.. <params.len:
    let param = params.sons[i].sym
    c.prc.slots[i] = (inUse: true, kind: slotFixedLet)
  c.prc.maxSlots = max(params.len, 1)

proc finalJumpTarget(c: PCtx; pc, diff: int) =
  internalAssert(-0x7fff < diff and diff < 0x7fff)
  let oldInstr = c.code[pc]
  # opcode and regA stay the same:
  c.code[pc] = ((oldInstr.uint32 and 0xffff'u32).uint32 or
                uint32(diff+wordExcess) shl 16'u32).TInstr

proc genGenericParams(c: PCtx; gp: PNode) =
  var base = c.prc.maxSlots
  for i in 0.. <gp.len:
    var param = gp.sons[i].sym
    param.position = base + i # XXX: fix this earlier; make it consistent with templates
    c.prc.slots[base + i] = (inUse: true, kind: slotFixedLet)
  c.prc.maxSlots = base + gp.len

proc optimizeJumps(c: PCtx; start: int) =
  const maxIterations = 10
  for i in start .. <c.code.len:
    let opc = c.code[i].opcode
    case opc
    of opcTJmp, opcFJmp:
      var reg = c.code[i].regA
      var d = i + c.code[i].jmpDiff
      for iters in countdown(maxIterations, 0):
        case c.code[d].opcode
        of opcJmp, opcJmpBack:
          d = d + c.code[d].jmpDiff
        of opcTJmp, opcFJmp:
          if c.code[d].regA != reg: break
          # tjmp x, 23
          # ...
          # tjmp x, 12
          # -- we know 'x' is true, and so can jump to 12+13:
          if c.code[d].opcode == opc:
            d = d + c.code[d].jmpDiff
          else:
            # tjmp x, 23
            # fjmp x, 22
            # We know 'x' is true so skip to the next instruction:
            d = d + 1
        else: break
      if d != i + c.code[i].jmpDiff:
        c.finalJumpTarget(i, d - i)
    of opcJmp, opcJmpBack:
      var d = i + c.code[i].jmpDiff
      var iters = maxIterations
      while c.code[d].opcode == opcJmp and iters > 0:
        d = d + c.code[d].jmpDiff
        dec iters
      if c.code[d].opcode == opcRet:
        # optimize 'jmp to ret' to 'ret' here
        c.code[i] = c.code[d]
      elif d != i + c.code[i].jmpDiff:
        c.finalJumpTarget(i, d - i)
    else: discard

proc genProc(c: PCtx; s: PSym): int =
  let x = s.ast.sons[optimizedCodePos]
  if x.kind == nkEmpty:
    #if s.name.s == "outterMacro" or s.name.s == "innerProc":
    #  echo "GENERATING CODE FOR ", s.name.s
    let last = c.code.len-1
    var eofInstr: TInstr
    if last >= 0 and c.code[last].opcode == opcEof:
      eofInstr = c.code[last]
      c.code.setLen(last)
      c.debug.setLen(last)
    #c.removeLastEof
    result = c.code.len+1 # skip the jump instruction
    s.ast.sons[optimizedCodePos] = newIntNode(nkIntLit, result)
    # thanks to the jmp we can add top level statements easily and also nest
    # procs easily:
    let body = s.getBody
    let procStart = c.xjmp(body, opcJmp, 0)
    var p = PProc(blocks: @[], sym: s)
    let oldPrc = c.prc
    c.prc = p
    # iterate over the parameters and allocate space for them:
    genParams(c, s.typ.n)

    # allocate additional space for any generically bound parameters
    if s.kind == skMacro and
       sfImmediate notin s.flags and
       s.ast[genericParamsPos].kind != nkEmpty:
      genGenericParams(c, s.ast[genericParamsPos])

    if tfCapturesEnv in s.typ.flags:
      #let env = s.ast.sons[paramsPos].lastSon.sym
      #assert env.position == 2
      c.prc.slots[c.prc.maxSlots] = (inUse: true, kind: slotFixedLet)
      inc c.prc.maxSlots
    gen(c, body)
    # generate final 'return' statement:
    c.gABC(body, opcRet)
    c.patch(procStart)
    c.gABC(body, opcEof, eofInstr.regA)
    c.optimizeJumps(result)
    s.offset = c.prc.maxSlots
    #if s.name.s == "calc":
    #  echo renderTree(body)
    #  c.echoCode(result)
    c.prc = oldPrc
  else:
    c.prc.maxSlots = s.offset
    result = x.intVal.int

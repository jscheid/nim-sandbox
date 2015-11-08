#
#
#           The Nim Compiler
#        (c) Copyright 2012 Andreas Rumpf
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.
#

# tree helper routines

import
  ast, astalgo, lexer, msgs, strutils, wordrecg

proc hasSon(father, son: PNode): bool =
  for i in countup(0, sonsLen(father) - 1):
    if father.sons[i] == son:
      return true
  result = false

proc cyclicTreeAux(n, s: PNode): bool =
  if n == nil:
    return false
  if hasSon(s, n):
    return true
  var m = sonsLen(s)
  addSon(s, n)
  if not (n.kind in {nkEmpty..nkNilLit}):
    for i in countup(0, sonsLen(n) - 1):
      if cyclicTreeAux(n.sons[i], s):
        return true
  result = false
  delSon(s, m)

proc cyclicTree*(n: PNode): bool =
  var s = newNodeI(nkEmpty, n.info)
  result = cyclicTreeAux(n, s)

proc exprStructuralEquivalent*(a, b: PNode; strictSymEquality=false): bool =
  result = false
  if a == b:
    result = true
  elif (a != nil) and (b != nil) and (a.kind == b.kind):
    case a.kind
    of nkSym:
      if strictSymEquality:
        result = a.sym == b.sym
      else:
        # don't go nuts here: same symbol as string is enough:
        result = a.sym.name.id == b.sym.name.id
    of nkIdent: result = a.ident.id == b.ident.id
    of nkCharLit..nkInt64Lit: result = a.intVal == b.intVal
    of nkFloatLit..nkFloat64Lit: result = a.floatVal == b.floatVal
    of nkStrLit..nkTripleStrLit: result = a.strVal == b.strVal
    of nkEmpty, nkNilLit, nkType: result = true
    else:
      if sonsLen(a) == sonsLen(b):
        for i in countup(0, sonsLen(a) - 1):
          if not exprStructuralEquivalent(a.sons[i], b.sons[i],
                                          strictSymEquality): return
        result = true

proc sameTree*(a, b: PNode): bool =
  result = false
  if a == b:
    result = true
  elif a != nil and b != nil and a.kind == b.kind:
    if a.flags != b.flags: return
    if a.info.line != b.info.line: return
    if a.info.col != b.info.col:
      return                  #if a.info.fileIndex <> b.info.fileIndex then exit;
    case a.kind
    of nkSym:
      # don't go nuts here: same symbol as string is enough:
      result = a.sym.name.id == b.sym.name.id
    of nkIdent: result = a.ident.id == b.ident.id
    of nkCharLit..nkInt64Lit: result = a.intVal == b.intVal
    of nkFloatLit..nkFloat64Lit: result = a.floatVal == b.floatVal
    of nkStrLit..nkTripleStrLit: result = a.strVal == b.strVal
    of nkEmpty, nkNilLit, nkType: result = true
    else:
      if sonsLen(a) == sonsLen(b):
        for i in countup(0, sonsLen(a) - 1):
          if not sameTree(a.sons[i], b.sons[i]): return
        result = true

proc getProcSym*(call: PNode): PSym =
  result = call.sons[0].sym

proc getOpSym*(op: PNode): PSym =
  if op.kind notin {nkCall, nkHiddenCallConv, nkCommand, nkCallStrLit}:
    result = nil
  else:
    if sonsLen(op) <= 0: internalError(op.info, "getOpSym")
    elif op.sons[0].kind == nkSym: result = op.sons[0].sym
    else: result = nil

proc getMagic*(op: PNode): TMagic =
  case op.kind
  of nkCallKinds:
    case op.sons[0].kind
    of nkSym: result = op.sons[0].sym.magic
    else: result = mNone
  else: result = mNone

proc treeToSym*(t: PNode): PSym =
  result = t.sym

proc isConstExpr*(n: PNode): bool =
  result = (n.kind in
      {nkCharLit..nkInt64Lit, nkStrLit..nkTripleStrLit,
       nkFloatLit..nkFloat64Lit, nkNilLit}) or (nfAllConst in n.flags)

proc isDeepConstExpr*(n: PNode): bool =
  case n.kind
  of nkCharLit..nkInt64Lit, nkStrLit..nkTripleStrLit,
      nkFloatLit..nkFloat64Lit, nkNilLit:
    result = true
  of nkExprEqExpr, nkExprColonExpr, nkHiddenStdConv, nkHiddenSubConv:
    result = isDeepConstExpr(n.sons[1])
  of nkCurly, nkBracket, nkPar, nkObjConstr, nkClosure:
    for i in 0 .. <n.len:
      if not isDeepConstExpr(n.sons[i]): return false
    # XXX once constant objects are supported by the codegen this needs to be
    # weakened:
    result = n.typ.isNil or n.typ.skipTypes({tyGenericInst, tyDistinct}).kind != tyObject
  else: discard

proc flattenTreeAux(d, a: PNode, op: TMagic) =
  if (getMagic(a) == op):     # a is a "leaf", so add it:
    for i in countup(1, sonsLen(a) - 1): # BUGFIX
      flattenTreeAux(d, a.sons[i], op)
  else:
    addSon(d, copyTree(a))

proc flattenTree*(root: PNode, op: TMagic): PNode =
  result = copyNode(root)
  if getMagic(root) == op:
    # BUGFIX: forget to copy prc
    addSon(result, copyNode(root.sons[0]))
    flattenTreeAux(result, root, op)

proc swapOperands*(op: PNode) =
  var tmp = op.sons[1]
  op.sons[1] = op.sons[2]
  op.sons[2] = tmp

proc isRange*(n: PNode): bool {.inline.} =
  if n.kind in nkCallKinds:
    if n[0].kind == nkIdent and n[0].ident.id == ord(wDotDot) or
        n[0].kind in {nkClosedSymChoice, nkOpenSymChoice} and
        n[0][1].sym.name.id == ord(wDotDot):
      result = true

proc whichPragma*(n: PNode): TSpecialWord =
  let key = if n.kind == nkExprColonExpr: n.sons[0] else: n
  if key.kind == nkIdent: result = whichKeyword(key.ident)

proc unnestStmts(n, result: PNode) =
  if n.kind == nkStmtList:
    for x in items(n): unnestStmts(x, result)
  elif n.kind notin {nkCommentStmt, nkNilLit}:
    result.add(n)

proc flattenStmts*(n: PNode): PNode =
  ## flattens a nested statement list; used for pattern matching
  result = newNodeI(nkStmtList, n.info)
  unnestStmts(n, result)
  if result.len == 1:
    result = result.sons[0]

proc extractRange*(k: TNodeKind, n: PNode, a, b: int): PNode =
  result = newNodeI(k, n.info, b-a+1)
  for i in 0 .. b-a: result.sons[i] = n.sons[i+a]

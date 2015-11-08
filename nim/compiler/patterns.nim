#
#
#           The Nim Compiler
#        (c) Copyright 2012 Andreas Rumpf
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.
#

## This module implements the pattern matching features for term rewriting
## macro support.

import
  ast, astalgo, types, semdata, sigmatch, msgs, idents, aliases, parampatterns,
  trees

type
  TPatternContext = object
    owner: PSym
    mapping: seq[PNode]  # maps formal parameters to nodes
    formals: int
    c: PContext
    subMatch: bool       # subnode matches are special
  PPatternContext = var TPatternContext

proc getLazy(c: PPatternContext, sym: PSym): PNode =
  if not isNil(c.mapping):
    result = c.mapping[sym.position]

proc putLazy(c: PPatternContext, sym: PSym, n: PNode) =
  if isNil(c.mapping): newSeq(c.mapping, c.formals)
  c.mapping[sym.position] = n

proc matches(c: PPatternContext, p, n: PNode): bool

proc canonKind(n: PNode): TNodeKind =
  ## nodekind canonilization for pattern matching
  result = n.kind
  case result
  of nkCallKinds: result = nkCall
  of nkStrLit..nkTripleStrLit: result = nkStrLit
  of nkFastAsgn: result = nkAsgn
  else: discard

proc sameKinds(a, b: PNode): bool {.inline.} =
  result = a.kind == b.kind or a.canonKind == b.canonKind

proc sameTrees(a, b: PNode): bool =
  if sameKinds(a, b):
    case a.kind
    of nkSym: result = a.sym == b.sym
    of nkIdent: result = a.ident.id == b.ident.id
    of nkCharLit..nkInt64Lit: result = a.intVal == b.intVal
    of nkFloatLit..nkFloat64Lit: result = a.floatVal == b.floatVal
    of nkStrLit..nkTripleStrLit: result = a.strVal == b.strVal
    of nkEmpty, nkNilLit: result = true
    of nkType: result = sameTypeOrNil(a.typ, b.typ)
    else:
      if sonsLen(a) == sonsLen(b):
        for i in countup(0, sonsLen(a) - 1):
          if not sameTrees(a.sons[i], b.sons[i]): return
        result = true

proc inSymChoice(sc, x: PNode): bool =
  if sc.kind == nkClosedSymChoice:
    for i in 0.. <sc.len:
      if sc.sons[i].sym == x.sym: return true
  elif sc.kind == nkOpenSymChoice:
    # same name suffices for open sym choices!
    result = sc.sons[0].sym.name.id == x.sym.name.id

proc checkTypes(c: PPatternContext, p: PSym, n: PNode): bool =
  # check param constraints first here as this is quite optimized:
  if p.constraint != nil:
    result = matchNodeKinds(p.constraint, n)
    if not result: return
  if isNil(n.typ):
    result = p.typ.kind in {tyEmpty, tyStmt}
  else:
    result = sigmatch.argtypeMatches(c.c, p.typ, n.typ)

proc isPatternParam(c: PPatternContext, p: PNode): bool {.inline.} =
  result = p.kind == nkSym and p.sym.kind == skParam and p.sym.owner == c.owner

proc matchChoice(c: PPatternContext, p, n: PNode): bool =
  for i in 1 .. <p.len:
    if matches(c, p.sons[i], n): return true

proc bindOrCheck(c: PPatternContext, param: PSym, n: PNode): bool =
  var pp = getLazy(c, param)
  if pp != nil:
    # check if we got the same pattern (already unified):
    result = sameTrees(pp, n) #matches(c, pp, n)
  elif n.kind == nkArgList or checkTypes(c, param, n):
    putLazy(c, param, n)
    result = true

proc gather(c: PPatternContext, param: PSym, n: PNode) =
  var pp = getLazy(c, param)
  if pp != nil and pp.kind == nkArgList:
    pp.add(n)
  else:
    pp = newNodeI(nkArgList, n.info, 1)
    pp.sons[0] = n
    putLazy(c, param, pp)

proc matchNested(c: PPatternContext, p, n: PNode, rpn: bool): bool =
  # match ``op * param`` or ``op *| param``
  proc matchStarAux(c: PPatternContext, op, n, arglist: PNode,
                    rpn: bool): bool =
    result = true
    if n.kind in nkCallKinds and matches(c, op.sons[1], n.sons[0]):
      for i in 1..sonsLen(n)-1:
        if not matchStarAux(c, op, n[i], arglist, rpn): return false
      if rpn: arglist.add(n.sons[0])
    elif n.kind == nkHiddenStdConv and n.sons[1].kind == nkBracket:
      let n = n.sons[1]
      for i in 0.. <n.len:
        if not matchStarAux(c, op, n[i], arglist, rpn): return false
    elif checkTypes(c, p.sons[2].sym, n):
      add(arglist, n)
    else:
      result = false

  if n.kind notin nkCallKinds: return false
  if matches(c, p.sons[1], n.sons[0]):
    var arglist = newNodeI(nkArgList, n.info)
    if matchStarAux(c, p, n, arglist, rpn):
      result = bindOrCheck(c, p.sons[2].sym, arglist)

proc matches(c: PPatternContext, p, n: PNode): bool =
  # hidden conversions (?)
  if nfNoRewrite in n.flags:
    result = false
  elif isPatternParam(c, p):
    result = bindOrCheck(c, p.sym, n)
  elif n.kind == nkSym and p.kind == nkIdent:
    result = p.ident.id == n.sym.name.id
  elif n.kind == nkSym and inSymChoice(p, n):
    result = true
  elif n.kind == nkSym and n.sym.kind == skConst:
    # try both:
    if p.kind == nkSym: result = p.sym == n.sym
    elif matches(c, p, n.sym.ast): result = true
  elif p.kind == nkPattern:
    # pattern operators: | *
    let opr = p.sons[0].ident.s
    case opr
    of "|": result = matchChoice(c, p, n)
    of "*": result = matchNested(c, p, n, rpn=false)
    of "**": result = matchNested(c, p, n, rpn=true)
    of "~": result = not matches(c, p.sons[1], n)
    else: internalError(p.info, "invalid pattern")
    # template {add(a, `&` * b)}(a: string{noalias}, b: varargs[string]) =
    #   add(a, b)
  elif p.kind == nkCurlyExpr:
    if p.sons[1].kind == nkPrefix:
      if matches(c, p.sons[0], n):
        gather(c, p.sons[1].sons[1].sym, n)
        result = true
    else:
      assert isPatternParam(c, p.sons[1])
      if matches(c, p.sons[0], n):
        result = bindOrCheck(c, p.sons[1].sym, n)
  elif sameKinds(p, n):
    case p.kind
    of nkSym: result = p.sym == n.sym
    of nkIdent: result = p.ident.id == n.ident.id
    of nkCharLit..nkInt64Lit: result = p.intVal == n.intVal
    of nkFloatLit..nkFloat64Lit: result = p.floatVal == n.floatVal
    of nkStrLit..nkTripleStrLit: result = p.strVal == n.strVal
    of nkEmpty, nkNilLit, nkType:
      result = true
    else:
      var plen = sonsLen(p)
      # special rule for p(X) ~ f(...); this also works for stuff like
      # partial case statements, etc! - Not really ... :-/
      let v = lastSon(p)
      if isPatternParam(c, v) and v.sym.typ.kind == tyVarargs:
        var arglist: PNode
        if plen <= sonsLen(n):
          for i in countup(0, plen - 2):
            if not matches(c, p.sons[i], n.sons[i]): return
          if plen == sonsLen(n) and lastSon(n).kind == nkHiddenStdConv and
              lastSon(n).sons[1].kind == nkBracket:
            # unpack varargs:
            let n = lastSon(n).sons[1]
            arglist = newNodeI(nkArgList, n.info, n.len)
            for i in 0.. <n.len: arglist.sons[i] = n.sons[i]
          else:
            arglist = newNodeI(nkArgList, n.info, sonsLen(n) - plen + 1)
            # f(1, 2, 3)
            # p(X)
            for i in countup(0, sonsLen(n) - plen):
              arglist.sons[i] = n.sons[i + plen - 1]
          return bindOrCheck(c, v.sym, arglist)
        elif plen-1 == sonsLen(n):
          for i in countup(0, plen - 2):
            if not matches(c, p.sons[i], n.sons[i]): return
          arglist = newNodeI(nkArgList, n.info)
          return bindOrCheck(c, v.sym, arglist)
      if plen == sonsLen(n):
        for i in countup(0, sonsLen(p) - 1):
          if not matches(c, p.sons[i], n.sons[i]): return
        result = true

proc matchStmtList(c: PPatternContext, p, n: PNode): PNode =
  proc matchRange(c: PPatternContext, p, n: PNode, i: int): bool =
    for j in 0 .. <p.len:
      if not matches(c, p.sons[j], n.sons[i+j]):
        # we need to undo any bindings:
        if not isNil(c.mapping): c.mapping = nil
        return false
    result = true

  if p.kind == nkStmtList and n.kind == p.kind and p.len < n.len:
    let n = flattenStmts(n)
    # no need to flatten 'p' here as that has already been done
    for i in 0 .. n.len - p.len:
      if matchRange(c, p, n, i):
        c.subMatch = true
        result = newNodeI(nkStmtList, n.info, 3)
        result.sons[0] = extractRange(nkStmtList, n, 0, i-1)
        result.sons[1] = extractRange(nkStmtList, n, i, i+p.len-1)
        result.sons[2] = extractRange(nkStmtList, n, i+p.len, n.len-1)
        break
  elif matches(c, p, n):
    result = n

proc aliasAnalysisRequested(params: PNode): bool =
  if params.len >= 2:
    for i in 1 .. < params.len:
      let param = params.sons[i].sym
      if whichAlias(param) != aqNone: return true

proc addToArgList(result, n: PNode) =
  if n.typ != nil and n.typ.kind != tyStmt:
    if n.kind != nkArgList: result.add(n)
    else:
      for i in 0 .. <n.len: result.add(n.sons[i])

proc applyRule*(c: PContext, s: PSym, n: PNode): PNode =
  ## returns a tree to semcheck if the rule triggered; nil otherwise
  var ctx: TPatternContext
  ctx.owner = s
  ctx.c = c
  ctx.formals = sonsLen(s.typ)-1
  var m = matchStmtList(ctx, s.ast.sons[patternPos], n)
  if isNil(m): return nil
  # each parameter should have been bound; we simply setup a call and
  # let semantic checking deal with the rest :-)
  result = newNodeI(nkCall, n.info)
  result.add(newSymNode(s, n.info))
  let params = s.typ.n
  let requiresAA = aliasAnalysisRequested(params)
  var args: PNode
  if requiresAA:
    args = newNodeI(nkArgList, n.info)
  for i in 1 .. < params.len:
    let param = params.sons[i].sym
    let x = getLazy(ctx, param)
    # couldn't bind parameter:
    if isNil(x): return nil
    result.add(x)
    if requiresAA: addToArgList(args, x)
  # perform alias analysis here:
  if requiresAA:
    for i in 1 .. < params.len:
      var rs = result.sons[i]
      let param = params.sons[i].sym
      case whichAlias(param)
      of aqNone: discard
      of aqShouldAlias:
        # it suffices that it aliases for sure with *some* other param:
        var ok = false
        for arg in items(args):
          if arg != rs and aliases.isPartOf(rs, arg) == arYes:
            ok = true
            break
        # constraint not fulfilled:
        if not ok: return nil
      of aqNoAlias:
        # it MUST not alias with any other param:
        var ok = true
        for arg in items(args):
          if arg != rs and aliases.isPartOf(rs, arg) != arNo:
            ok = false
            break
        # constraint not fulfilled:
        if not ok: return nil

  markUsed(n.info, s)
  if ctx.subMatch:
    assert m.len == 3
    m.sons[1] = result
    result = m

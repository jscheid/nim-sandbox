#
#
#           The Nim Compiler
#        (c) Copyright 2012 Andreas Rumpf
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.
#

## Simple alias analysis for the HLO and the code generators.

import
  ast, astalgo, types, trees, intsets, msgs

type
  TAnalysisResult* = enum
    arNo, arMaybe, arYes

proc isPartOfAux(a, b: PType, marker: var IntSet): TAnalysisResult

proc isPartOfAux(n: PNode, b: PType, marker: var IntSet): TAnalysisResult =
  result = arNo
  case n.kind
  of nkRecList:
    for i in countup(0, sonsLen(n) - 1):
      result = isPartOfAux(n.sons[i], b, marker)
      if result == arYes: return
  of nkRecCase:
    assert(n.sons[0].kind == nkSym)
    result = isPartOfAux(n.sons[0], b, marker)
    if result == arYes: return
    for i in countup(1, sonsLen(n) - 1):
      case n.sons[i].kind
      of nkOfBranch, nkElse:
        result = isPartOfAux(lastSon(n.sons[i]), b, marker)
        if result == arYes: return
      else: internalError("isPartOfAux(record case branch)")
  of nkSym:
    result = isPartOfAux(n.sym.typ, b, marker)
  else: internalError(n.info, "isPartOfAux()")

proc isPartOfAux(a, b: PType, marker: var IntSet): TAnalysisResult =
  result = arNo
  if a == nil or b == nil: return
  if containsOrIncl(marker, a.id): return
  if compareTypes(a, b, dcEqIgnoreDistinct): return arYes
  case a.kind
  of tyObject:
    result = isPartOfAux(a.sons[0], b, marker)
    if result == arNo: result = isPartOfAux(a.n, b, marker)
  of tyGenericInst, tyDistinct:
    result = isPartOfAux(lastSon(a), b, marker)
  of tyArray, tyArrayConstr, tySet, tyTuple:
    for i in countup(0, sonsLen(a) - 1):
      result = isPartOfAux(a.sons[i], b, marker)
      if result == arYes: return
  else: discard

proc isPartOf(a, b: PType): TAnalysisResult =
  ## checks iff 'a' can be part of 'b'. Iterates over VALUE types!
  var marker = initIntSet()
  # watch out: parameters reversed because I'm too lazy to change the code...
  result = isPartOfAux(b, a, marker)

proc isPartOf*(a, b: PNode): TAnalysisResult =
  ## checks if location `a` can be part of location `b`. We treat seqs and
  ## strings as pointers because the code gen often just passes them as such.
  ##
  ## Note: `a` can only be part of `b`, if `a`'s type can be part of `b`'s
  ## type. Since however type analysis is more expensive, we perform it only
  ## if necessary.
  ##
  ## cases:
  ##
  ## YES-cases:
  ##  x    <| x   # for general trees
  ##  x[]  <| x
  ##  x[i] <| x
  ##  x.f  <| x
  ##
  ## NO-cases:
  ## x           !<| y    # depending on type and symbol kind
  ## x[constA]   !<| x[constB]
  ## x.f         !<| x.g
  ## x.f         !<| y.f  iff x !<= y
  ##
  ## MAYBE-cases:
  ##
  ##  x[] ?<| y[]   iff compatible type
  ##
  ##
  ##  x[]  ?<| y  depending on type
  ##
  if a.kind == b.kind:
    case a.kind
    of nkSym:
      const varKinds = {skVar, skTemp, skProc}
      # same symbol: aliasing:
      if a.sym.id == b.sym.id: result = arYes
      elif a.sym.kind in varKinds or b.sym.kind in varKinds:
        # actually, a param could alias a var but we know that cannot happen
        # here. XXX make this more generic
        result = arNo
      else:
        # use expensive type check:
        if isPartOf(a.sym.typ, b.sym.typ) != arNo:
          result = arMaybe
    of nkBracketExpr:
      result = isPartOf(a[0], b[0])
      if len(a) >= 2 and len(b) >= 2:
        # array accesses:
        if result == arYes and isDeepConstExpr(a[1]) and isDeepConstExpr(b[1]):
          # we know it's the same array and we have 2 constant indexes;
          # if they are
          var x = if a[1].kind == nkHiddenStdConv: a[1][1] else: a[1]
          var y = if b[1].kind == nkHiddenStdConv: b[1][1] else: b[1]

          if sameValue(x, y): result = arYes
          else: result = arNo
        # else: maybe and no are accurate
      else:
        # pointer derefs:
        if result != arYes:
          if isPartOf(a.typ, b.typ) != arNo: result = arMaybe

    of nkDotExpr:
      result = isPartOf(a[0], b[0])
      if result != arNo:
        # if the fields are different, it's not the same location
        if a[1].sym.id != b[1].sym.id:
          result = arNo

    of nkHiddenDeref, nkDerefExpr:
      result = isPartOf(a[0], b[0])
      # weaken because of indirection:
      if result != arYes:
        if isPartOf(a.typ, b.typ) != arNo: result = arMaybe

    of nkHiddenStdConv, nkHiddenSubConv, nkConv:
      result = isPartOf(a[1], b[1])
    of nkObjUpConv, nkObjDownConv, nkCheckedFieldExpr:
      result = isPartOf(a[0], b[0])
    else: discard
    # Calls return a new location, so a default of ``arNo`` is fine.
  else:
    # go down recursively; this is quite demanding:
    const
      Ix0Kinds = {nkDotExpr, nkBracketExpr, nkObjUpConv, nkObjDownConv,
                  nkCheckedFieldExpr, nkHiddenAddr}
      Ix1Kinds = {nkHiddenStdConv, nkHiddenSubConv, nkConv}
      DerefKinds = {nkHiddenDeref, nkDerefExpr}
    case b.kind
    of Ix0Kinds:
      # a* !<| b.f  iff  a* !<| b
      result = isPartOf(a, b[0])

    of DerefKinds:
      # a* !<| b[] iff
      if isPartOf(a.typ, b.typ) != arNo:
        result = isPartOf(a, b[0])
        if result == arNo: result = arMaybe

    of Ix1Kinds:
      # a* !<| T(b)  iff a* !<| b
      result = isPartOf(a, b[1])

    of nkSym:
      # b is an atom, so we have to check a:
      case a.kind
      of Ix0Kinds:
        # a.f !<| b*  iff  a.f !<| b*
        result = isPartOf(a[0], b)
      of Ix1Kinds:
        result = isPartOf(a[1], b)

      of DerefKinds:
        if isPartOf(a.typ, b.typ) != arNo:
          result = isPartOf(a[0], b)
          if result == arNo: result = arMaybe
      else: discard
    else: discard


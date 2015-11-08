#
#
#           The Nim Compiler
#        (c) Copyright 2013 Andreas Rumpf
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.
#

## Type info generation for the JS backend.

proc genTypeInfo(p: PProc, typ: PType): Rope
proc genObjectFields(p: PProc, typ: PType, n: PNode): Rope =
  var
    s, u: Rope
    length: int
    field: PSym
    b: PNode
  result = nil
  case n.kind
  of nkRecList:
    length = sonsLen(n)
    if length == 1:
      result = genObjectFields(p, typ, n.sons[0])
    else:
      s = nil
      for i in countup(0, length - 1):
        if i > 0: add(s, ", " & tnl)
        add(s, genObjectFields(p, typ, n.sons[i]))
      result = ("{kind: 2, len: $1, offset: 0, " &
          "typ: null, name: null, sons: [$2]}") % [rope(length), s]
  of nkSym:
    field = n.sym
    s = genTypeInfo(p, field.typ)
    result = ("{kind: 1, offset: \"$1\", len: 0, " &
        "typ: $2, name: $3, sons: null}") %
                   [mangleName(field), s, makeJSString(field.name.s)]
  of nkRecCase:
    length = sonsLen(n)
    if (n.sons[0].kind != nkSym): internalError(n.info, "genObjectFields")
    field = n.sons[0].sym
    s = genTypeInfo(p, field.typ)
    for i in countup(1, length - 1):
      b = n.sons[i]           # branch
      u = nil
      case b.kind
      of nkOfBranch:
        if sonsLen(b) < 2:
          internalError(b.info, "genObjectFields; nkOfBranch broken")
        for j in countup(0, sonsLen(b) - 2):
          if u != nil: add(u, ", ")
          if b.sons[j].kind == nkRange:
            addf(u, "[$1, $2]", [rope(getOrdValue(b.sons[j].sons[0])),
                                 rope(getOrdValue(b.sons[j].sons[1]))])
          else:
            add(u, rope(getOrdValue(b.sons[j])))
      of nkElse:
        u = rope(lengthOrd(field.typ))
      else: internalError(n.info, "genObjectFields(nkRecCase)")
      if result != nil: add(result, ", " & tnl)
      addf(result, "[SetConstr($1), $2]",
           [u, genObjectFields(p, typ, lastSon(b))])
    result = ("{kind: 3, offset: \"$1\", len: $3, " &
        "typ: $2, name: $4, sons: [$5]}") % [mangleName(field), s,
        rope(lengthOrd(field.typ)), makeJSString(field.name.s), result]
  else: internalError(n.info, "genObjectFields")

proc genObjectInfo(p: PProc, typ: PType, name: Rope) =
  var s = ("var $1 = {size: 0, kind: $2, base: null, node: null, " &
           "finalizer: null};$n") % [name, rope(ord(typ.kind))]
  prepend(p.g.typeInfo, s)
  addf(p.g.typeInfo, "var NNI$1 = $2;$n",
       [rope(typ.id), genObjectFields(p, typ, typ.n)])
  addf(p.g.typeInfo, "$1.node = NNI$2;$n", [name, rope(typ.id)])
  if (typ.kind == tyObject) and (typ.sons[0] != nil):
    addf(p.g.typeInfo, "$1.base = $2;$n",
         [name, genTypeInfo(p, typ.sons[0])])

proc genTupleFields(p: PProc, typ: PType): Rope =
  var s: Rope = nil
  for i in 0 .. <typ.len:
    if i > 0: add(s, ", " & tnl)
    s.addf("{kind: 1, offset: \"Field$1\", len: 0, " &
           "typ: $2, name: \"Field$1\", sons: null}",
           [i.rope, genTypeInfo(p, typ.sons[i])])
  result = ("{kind: 2, len: $1, offset: 0, " &
            "typ: null, name: null, sons: [$2]}") % [rope(typ.len), s]

proc genTupleInfo(p: PProc, typ: PType, name: Rope) =
  var s = ("var $1 = {size: 0, kind: $2, base: null, node: null, " &
           "finalizer: null};$n") % [name, rope(ord(typ.kind))]
  prepend(p.g.typeInfo, s)
  addf(p.g.typeInfo, "var NNI$1 = $2;$n",
       [rope(typ.id), genTupleFields(p, typ)])
  addf(p.g.typeInfo, "$1.node = NNI$2;$n", [name, rope(typ.id)])

proc genEnumInfo(p: PProc, typ: PType, name: Rope) =
  let length = sonsLen(typ.n)
  var s: Rope = nil
  for i in countup(0, length - 1):
    if (typ.n.sons[i].kind != nkSym): internalError(typ.n.info, "genEnumInfo")
    let field = typ.n.sons[i].sym
    if i > 0: add(s, ", " & tnl)
    let extName = if field.ast == nil: field.name.s else: field.ast.strVal
    addf(s, "{kind: 1, offset: $1, typ: $2, name: $3, len: 0, sons: null}",
         [rope(field.position), name, makeJSString(extName)])
  var n = ("var NNI$1 = {kind: 2, offset: 0, typ: null, " &
      "name: null, len: $2, sons: [$3]};$n") % [rope(typ.id), rope(length), s]
  s = ("var $1 = {size: 0, kind: $2, base: null, node: null, " &
       "finalizer: null};$n") % [name, rope(ord(typ.kind))]
  prepend(p.g.typeInfo, s)
  add(p.g.typeInfo, n)
  addf(p.g.typeInfo, "$1.node = NNI$2;$n", [name, rope(typ.id)])
  if typ.sons[0] != nil:
    addf(p.g.typeInfo, "$1.base = $2;$n",
         [name, genTypeInfo(p, typ.sons[0])])

proc genTypeInfo(p: PProc, typ: PType): Rope =
  let t = typ.skipTypes({tyGenericInst})
  result = "NTI$1" % [rope(t.id)]
  if containsOrIncl(p.g.typeInfoGenerated, t.id): return
  case t.kind
  of tyDistinct:
    result = genTypeInfo(p, t.sons[0])
  of tyPointer, tyProc, tyBool, tyChar, tyCString, tyString, tyInt..tyUInt64:
    var s =
      "var $1 = {size: 0,kind: $2,base: null,node: null,finalizer: null};$n" %
      [result, rope(ord(t.kind))]
    prepend(p.g.typeInfo, s)
  of tyVar, tyRef, tyPtr, tySequence, tyRange, tySet:
    var s =
      "var $1 = {size: 0,kind: $2,base: null,node: null,finalizer: null};$n" %
              [result, rope(ord(t.kind))]
    prepend(p.g.typeInfo, s)
    addf(p.g.typeInfo, "$1.base = $2;$n",
         [result, genTypeInfo(p, t.lastSon)])
  of tyArrayConstr, tyArray:
    var s =
      "var $1 = {size: 0,kind: $2,base: null,node: null,finalizer: null};$n" %
              [result, rope(ord(t.kind))]
    prepend(p.g.typeInfo, s)
    addf(p.g.typeInfo, "$1.base = $2;$n",
         [result, genTypeInfo(p, t.sons[1])])
  of tyEnum: genEnumInfo(p, t, result)
  of tyObject: genObjectInfo(p, t, result)
  of tyTuple: genTupleInfo(p, t, result)
  else: internalError("genTypeInfo(" & $t.kind & ')')

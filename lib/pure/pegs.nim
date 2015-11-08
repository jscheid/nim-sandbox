#
#
#            Nim's Runtime Library
#        (c) Copyright 2012 Andreas Rumpf
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.
#

## Simple PEG (Parsing expression grammar) matching. Uses no memorization, but
## uses superoperators and symbol inlining to improve performance. Note:
## Matching performance is hopefully competitive with optimized regular
## expression engines.
##
## .. include:: ../doc/pegdocs.txt
##

include "system/inclrtl"

const
  useUnicode = true ## change this to deactivate proper UTF-8 support

import
  strutils

when useUnicode:
  import unicode

const
  InlineThreshold = 5  ## number of leaves; -1 to disable inlining
  MaxSubpatterns* = 20 ## defines the maximum number of subpatterns that
                       ## can be captured. More subpatterns cannot be captured!

type
  PegKind = enum
    pkEmpty,
    pkAny,              ## any character (.)
    pkAnyRune,          ## any Unicode character (_)
    pkNewLine,          ## CR-LF, LF, CR
    pkLetter,           ## Unicode letter
    pkLower,            ## Unicode lower case letter
    pkUpper,            ## Unicode upper case letter
    pkTitle,            ## Unicode title character
    pkWhitespace,       ## Unicode whitespace character
    pkTerminal,
    pkTerminalIgnoreCase,
    pkTerminalIgnoreStyle,
    pkChar,             ## single character to match
    pkCharChoice,
    pkNonTerminal,
    pkSequence,         ## a b c ... --> Internal DSL: peg(a, b, c)
    pkOrderedChoice,    ## a / b / ... --> Internal DSL: a / b or /[a, b, c]
    pkGreedyRep,        ## a*     --> Internal DSL: *a
                        ## a+     --> (a a*)
    pkGreedyRepChar,    ## x* where x is a single character (superop)
    pkGreedyRepSet,     ## [set]* (superop)
    pkGreedyAny,        ## .* or _* (superop)
    pkOption,           ## a?     --> Internal DSL: ?a
    pkAndPredicate,     ## &a     --> Internal DSL: &a
    pkNotPredicate,     ## !a     --> Internal DSL: !a
    pkCapture,          ## {a}    --> Internal DSL: capture(a)
    pkBackRef,          ## $i     --> Internal DSL: backref(i)
    pkBackRefIgnoreCase,
    pkBackRefIgnoreStyle,
    pkSearch,           ## @a     --> Internal DSL: !*a
    pkCapturedSearch,   ## {@} a  --> Internal DSL: !*\a
    pkRule,             ## a <- b
    pkList,             ## a, b
    pkStartAnchor       ## ^      --> Internal DSL: startAnchor()
  NonTerminalFlag = enum
    ntDeclared, ntUsed
  NonTerminalObj = object         ## represents a non terminal symbol
    name: string                  ## the name of the symbol
    line: int                     ## line the symbol has been declared/used in
    col: int                      ## column the symbol has been declared/used in
    flags: set[NonTerminalFlag]   ## the nonterminal's flags
    rule: Node                   ## the rule that the symbol refers to
  Node {.shallow.} = object
    case kind: PegKind
    of pkEmpty..pkWhitespace: nil
    of pkTerminal, pkTerminalIgnoreCase, pkTerminalIgnoreStyle: term: string
    of pkChar, pkGreedyRepChar: ch: char
    of pkCharChoice, pkGreedyRepSet: charChoice: ref set[char]
    of pkNonTerminal: nt: NonTerminal
    of pkBackRef..pkBackRefIgnoreStyle: index: range[0..MaxSubpatterns]
    else: sons: seq[Node]
  NonTerminal* = ref NonTerminalObj

  Peg* = Node ## type that represents a PEG

{.deprecated: [TPeg: Peg, TNode: Node].}

proc term*(t: string): Peg {.nosideEffect, rtl, extern: "npegs$1Str".} =
  ## constructs a PEG from a terminal string
  if t.len != 1:
    result.kind = pkTerminal
    result.term = t
  else:
    result.kind = pkChar
    result.ch = t[0]

proc termIgnoreCase*(t: string): Peg {.
  nosideEffect, rtl, extern: "npegs$1".} =
  ## constructs a PEG from a terminal string; ignore case for matching
  result.kind = pkTerminalIgnoreCase
  result.term = t

proc termIgnoreStyle*(t: string): Peg {.
  nosideEffect, rtl, extern: "npegs$1".} =
  ## constructs a PEG from a terminal string; ignore style for matching
  result.kind = pkTerminalIgnoreStyle
  result.term = t

proc term*(t: char): Peg {.nosideEffect, rtl, extern: "npegs$1Char".} =
  ## constructs a PEG from a terminal char
  assert t != '\0'
  result.kind = pkChar
  result.ch = t

proc charSet*(s: set[char]): Peg {.nosideEffect, rtl, extern: "npegs$1".} =
  ## constructs a PEG from a character set `s`
  assert '\0' notin s
  result.kind = pkCharChoice
  new(result.charChoice)
  result.charChoice[] = s

proc len(a: Peg): int {.inline.} = return a.sons.len
proc add(d: var Peg, s: Peg) {.inline.} = add(d.sons, s)

proc addChoice(dest: var Peg, elem: Peg) =
  var L = dest.len-1
  if L >= 0 and dest.sons[L].kind == pkCharChoice:
    # caution! Do not introduce false aliasing here!
    case elem.kind
    of pkCharChoice:
      dest.sons[L] = charSet(dest.sons[L].charChoice[] + elem.charChoice[])
    of pkChar:
      dest.sons[L] = charSet(dest.sons[L].charChoice[] + {elem.ch})
    else: add(dest, elem)
  else: add(dest, elem)

template multipleOp(k: PegKind, localOpt: expr) =
  result.kind = k
  result.sons = @[]
  for x in items(a):
    if x.kind == k:
      for y in items(x.sons):
        localOpt(result, y)
    else:
      localOpt(result, x)
  if result.len == 1:
    result = result.sons[0]

proc `/`*(a: varargs[Peg]): Peg {.
  nosideEffect, rtl, extern: "npegsOrderedChoice".} =
  ## constructs an ordered choice with the PEGs in `a`
  multipleOp(pkOrderedChoice, addChoice)

proc addSequence(dest: var Peg, elem: Peg) =
  var L = dest.len-1
  if L >= 0 and dest.sons[L].kind == pkTerminal:
    # caution! Do not introduce false aliasing here!
    case elem.kind
    of pkTerminal:
      dest.sons[L] = term(dest.sons[L].term & elem.term)
    of pkChar:
      dest.sons[L] = term(dest.sons[L].term & elem.ch)
    else: add(dest, elem)
  else: add(dest, elem)

proc sequence*(a: varargs[Peg]): Peg {.
  nosideEffect, rtl, extern: "npegs$1".} =
  ## constructs a sequence with all the PEGs from `a`
  multipleOp(pkSequence, addSequence)

proc `?`*(a: Peg): Peg {.nosideEffect, rtl, extern: "npegsOptional".} =
  ## constructs an optional for the PEG `a`
  if a.kind in {pkOption, pkGreedyRep, pkGreedyAny, pkGreedyRepChar,
                pkGreedyRepSet}:
    # a* ?  --> a*
    # a? ?  --> a?
    result = a
  else:
    result.kind = pkOption
    result.sons = @[a]

proc `*`*(a: Peg): Peg {.nosideEffect, rtl, extern: "npegsGreedyRep".} =
  ## constructs a "greedy repetition" for the PEG `a`
  case a.kind
  of pkGreedyRep, pkGreedyRepChar, pkGreedyRepSet, pkGreedyAny, pkOption:
    assert false
    # produces endless loop!
  of pkChar:
    result.kind = pkGreedyRepChar
    result.ch = a.ch
  of pkCharChoice:
    result.kind = pkGreedyRepSet
    result.charChoice = a.charChoice # copying a reference suffices!
  of pkAny, pkAnyRune:
    result.kind = pkGreedyAny
  else:
    result.kind = pkGreedyRep
    result.sons = @[a]

proc `!*`*(a: Peg): Peg {.nosideEffect, rtl, extern: "npegsSearch".} =
  ## constructs a "search" for the PEG `a`
  result.kind = pkSearch
  result.sons = @[a]

proc `!*\`*(a: Peg): Peg {.noSideEffect, rtl,
                             extern: "npgegsCapturedSearch".} =
  ## constructs a "captured search" for the PEG `a`
  result.kind = pkCapturedSearch
  result.sons = @[a]

proc `+`*(a: Peg): Peg {.nosideEffect, rtl, extern: "npegsGreedyPosRep".} =
  ## constructs a "greedy positive repetition" with the PEG `a`
  return sequence(a, *a)

proc `&`*(a: Peg): Peg {.nosideEffect, rtl, extern: "npegsAndPredicate".} =
  ## constructs an "and predicate" with the PEG `a`
  result.kind = pkAndPredicate
  result.sons = @[a]

proc `!`*(a: Peg): Peg {.nosideEffect, rtl, extern: "npegsNotPredicate".} =
  ## constructs a "not predicate" with the PEG `a`
  result.kind = pkNotPredicate
  result.sons = @[a]

proc any*: Peg {.inline.} =
  ## constructs the PEG `any character`:idx: (``.``)
  result.kind = pkAny

proc anyRune*: Peg {.inline.} =
  ## constructs the PEG `any rune`:idx: (``_``)
  result.kind = pkAnyRune

proc newLine*: Peg {.inline.} =
  ## constructs the PEG `newline`:idx: (``\n``)
  result.kind = pkNewLine

proc unicodeLetter*: Peg {.inline.} =
  ## constructs the PEG ``\letter`` which matches any Unicode letter.
  result.kind = pkLetter

proc unicodeLower*: Peg {.inline.} =
  ## constructs the PEG ``\lower`` which matches any Unicode lowercase letter.
  result.kind = pkLower

proc unicodeUpper*: Peg {.inline.} =
  ## constructs the PEG ``\upper`` which matches any Unicode uppercase letter.
  result.kind = pkUpper

proc unicodeTitle*: Peg {.inline.} =
  ## constructs the PEG ``\title`` which matches any Unicode title letter.
  result.kind = pkTitle

proc unicodeWhitespace*: Peg {.inline.} =
  ## constructs the PEG ``\white`` which matches any Unicode
  ## whitespace character.
  result.kind = pkWhitespace

proc startAnchor*: Peg {.inline.} =
  ## constructs the PEG ``^`` which matches the start of the input.
  result.kind = pkStartAnchor

proc endAnchor*: Peg {.inline.} =
  ## constructs the PEG ``$`` which matches the end of the input.
  result = !any()

proc capture*(a: Peg): Peg {.nosideEffect, rtl, extern: "npegsCapture".} =
  ## constructs a capture with the PEG `a`
  result.kind = pkCapture
  result.sons = @[a]

proc backref*(index: range[1..MaxSubpatterns]): Peg {.
  nosideEffect, rtl, extern: "npegs$1".} =
  ## constructs a back reference of the given `index`. `index` starts counting
  ## from 1.
  result.kind = pkBackRef
  result.index = index-1

proc backrefIgnoreCase*(index: range[1..MaxSubpatterns]): Peg {.
  nosideEffect, rtl, extern: "npegs$1".} =
  ## constructs a back reference of the given `index`. `index` starts counting
  ## from 1. Ignores case for matching.
  result.kind = pkBackRefIgnoreCase
  result.index = index-1

proc backrefIgnoreStyle*(index: range[1..MaxSubpatterns]): Peg {.
  nosideEffect, rtl, extern: "npegs$1".}=
  ## constructs a back reference of the given `index`. `index` starts counting
  ## from 1. Ignores style for matching.
  result.kind = pkBackRefIgnoreStyle
  result.index = index-1

proc spaceCost(n: Peg): int =
  case n.kind
  of pkEmpty: discard
  of pkTerminal, pkTerminalIgnoreCase, pkTerminalIgnoreStyle, pkChar,
     pkGreedyRepChar, pkCharChoice, pkGreedyRepSet,
     pkAny..pkWhitespace, pkGreedyAny:
    result = 1
  of pkNonTerminal:
    # we cannot inline a rule with a non-terminal
    result = InlineThreshold+1
  else:
    for i in 0..n.len-1:
      inc(result, spaceCost(n.sons[i]))
      if result >= InlineThreshold: break

proc nonterminal*(n: NonTerminal): Peg {.
  nosideEffect, rtl, extern: "npegs$1".} =
  ## constructs a PEG that consists of the nonterminal symbol
  assert n != nil
  if ntDeclared in n.flags and spaceCost(n.rule) < InlineThreshold:
    when false: echo "inlining symbol: ", n.name
    result = n.rule # inlining of rule enables better optimizations
  else:
    result.kind = pkNonTerminal
    result.nt = n

proc newNonTerminal*(name: string, line, column: int): NonTerminal {.
  nosideEffect, rtl, extern: "npegs$1".} =
  ## constructs a nonterminal symbol
  new(result)
  result.name = name
  result.line = line
  result.col = column

template letters*: expr =
  ## expands to ``charset({'A'..'Z', 'a'..'z'})``
  charSet({'A'..'Z', 'a'..'z'})

template digits*: expr =
  ## expands to ``charset({'0'..'9'})``
  charSet({'0'..'9'})

template whitespace*: expr =
  ## expands to ``charset({' ', '\9'..'\13'})``
  charSet({' ', '\9'..'\13'})

template identChars*: expr =
  ## expands to ``charset({'a'..'z', 'A'..'Z', '0'..'9', '_'})``
  charSet({'a'..'z', 'A'..'Z', '0'..'9', '_'})

template identStartChars*: expr =
  ## expands to ``charset({'A'..'Z', 'a'..'z', '_'})``
  charSet({'a'..'z', 'A'..'Z', '_'})

template ident*: expr =
  ## same as ``[a-zA-Z_][a-zA-z_0-9]*``; standard identifier
  sequence(charSet({'a'..'z', 'A'..'Z', '_'}),
           *charSet({'a'..'z', 'A'..'Z', '0'..'9', '_'}))

template natural*: expr =
  ## same as ``\d+``
  +digits

# ------------------------- debugging -----------------------------------------

proc esc(c: char, reserved = {'\0'..'\255'}): string =
  case c
  of '\b': result = "\\b"
  of '\t': result = "\\t"
  of '\c': result = "\\c"
  of '\L': result = "\\l"
  of '\v': result = "\\v"
  of '\f': result = "\\f"
  of '\e': result = "\\e"
  of '\a': result = "\\a"
  of '\\': result = "\\\\"
  of 'a'..'z', 'A'..'Z', '0'..'9', '_': result = $c
  elif c < ' ' or c >= '\128': result = '\\' & $ord(c)
  elif c in reserved: result = '\\' & c
  else: result = $c

proc singleQuoteEsc(c: char): string = return "'" & esc(c, {'\''}) & "'"

proc singleQuoteEsc(str: string): string =
  result = "'"
  for c in items(str): add result, esc(c, {'\''})
  add result, '\''

proc charSetEscAux(cc: set[char]): string =
  const reserved = {'^', '-', ']'}
  result = ""
  var c1 = 0
  while c1 <= 0xff:
    if chr(c1) in cc:
      var c2 = c1
      while c2 < 0xff and chr(succ(c2)) in cc: inc(c2)
      if c1 == c2:
        add result, esc(chr(c1), reserved)
      elif c2 == succ(c1):
        add result, esc(chr(c1), reserved) & esc(chr(c2), reserved)
      else:
        add result, esc(chr(c1), reserved) & '-' & esc(chr(c2), reserved)
      c1 = c2
    inc(c1)

proc charSetEsc(cc: set[char]): string =
  if card(cc) >= 128+64:
    result = "[^" & charSetEscAux({'\1'..'\xFF'} - cc) & ']'
  else:
    result = '[' & charSetEscAux(cc) & ']'

proc toStrAux(r: Peg, res: var string) =
  case r.kind
  of pkEmpty: add(res, "()")
  of pkAny: add(res, '.')
  of pkAnyRune: add(res, '_')
  of pkLetter: add(res, "\\letter")
  of pkLower: add(res, "\\lower")
  of pkUpper: add(res, "\\upper")
  of pkTitle: add(res, "\\title")
  of pkWhitespace: add(res, "\\white")

  of pkNewLine: add(res, "\\n")
  of pkTerminal: add(res, singleQuoteEsc(r.term))
  of pkTerminalIgnoreCase:
    add(res, 'i')
    add(res, singleQuoteEsc(r.term))
  of pkTerminalIgnoreStyle:
    add(res, 'y')
    add(res, singleQuoteEsc(r.term))
  of pkChar: add(res, singleQuoteEsc(r.ch))
  of pkCharChoice: add(res, charSetEsc(r.charChoice[]))
  of pkNonTerminal: add(res, r.nt.name)
  of pkSequence:
    add(res, '(')
    toStrAux(r.sons[0], res)
    for i in 1 .. high(r.sons):
      add(res, ' ')
      toStrAux(r.sons[i], res)
    add(res, ')')
  of pkOrderedChoice:
    add(res, '(')
    toStrAux(r.sons[0], res)
    for i in 1 .. high(r.sons):
      add(res, " / ")
      toStrAux(r.sons[i], res)
    add(res, ')')
  of pkGreedyRep:
    toStrAux(r.sons[0], res)
    add(res, '*')
  of pkGreedyRepChar:
    add(res, singleQuoteEsc(r.ch))
    add(res, '*')
  of pkGreedyRepSet:
    add(res, charSetEsc(r.charChoice[]))
    add(res, '*')
  of pkGreedyAny:
    add(res, ".*")
  of pkOption:
    toStrAux(r.sons[0], res)
    add(res, '?')
  of pkAndPredicate:
    add(res, '&')
    toStrAux(r.sons[0], res)
  of pkNotPredicate:
    add(res, '!')
    toStrAux(r.sons[0], res)
  of pkSearch:
    add(res, '@')
    toStrAux(r.sons[0], res)
  of pkCapturedSearch:
    add(res, "{@}")
    toStrAux(r.sons[0], res)
  of pkCapture:
    add(res, '{')
    toStrAux(r.sons[0], res)
    add(res, '}')
  of pkBackRef:
    add(res, '$')
    add(res, $r.index)
  of pkBackRefIgnoreCase:
    add(res, "i$")
    add(res, $r.index)
  of pkBackRefIgnoreStyle:
    add(res, "y$")
    add(res, $r.index)
  of pkRule:
    toStrAux(r.sons[0], res)
    add(res, " <- ")
    toStrAux(r.sons[1], res)
  of pkList:
    for i in 0 .. high(r.sons):
      toStrAux(r.sons[i], res)
      add(res, "\n")
  of pkStartAnchor:
    add(res, '^')

proc `$` *(r: Peg): string {.nosideEffect, rtl, extern: "npegsToString".} =
  ## converts a PEG to its string representation
  result = ""
  toStrAux(r, result)

# --------------------- core engine -------------------------------------------

type
  Captures* = object ## contains the captured substrings.
    matches: array[0..MaxSubpatterns-1, tuple[first, last: int]]
    ml: int
    origStart: int

{.deprecated: [TCaptures: Captures].}

proc bounds*(c: Captures,
             i: range[0..MaxSubpatterns-1]): tuple[first, last: int] =
  ## returns the bounds ``[first..last]`` of the `i`'th capture.
  result = c.matches[i]

when not useUnicode:
  type
    Rune = char
  template fastRuneAt(s, i, ch: expr) =
    ch = s[i]
    inc(i)
  template runeLenAt(s, i: expr): expr = 1

  proc isAlpha(a: char): bool {.inline.} = return a in {'a'..'z','A'..'Z'}
  proc isUpper(a: char): bool {.inline.} = return a in {'A'..'Z'}
  proc isLower(a: char): bool {.inline.} = return a in {'a'..'z'}
  proc isTitle(a: char): bool {.inline.} = return false
  proc isWhiteSpace(a: char): bool {.inline.} = return a in {' ', '\9'..'\13'}

proc rawMatch*(s: string, p: Peg, start: int, c: var Captures): int {.
               nosideEffect, rtl, extern: "npegs$1".} =
  ## low-level matching proc that implements the PEG interpreter. Use this
  ## for maximum efficiency (every other PEG operation ends up calling this
  ## proc).
  ## Returns -1 if it does not match, else the length of the match
  case p.kind
  of pkEmpty: result = 0 # match of length 0
  of pkAny:
    if s[start] != '\0': result = 1
    else: result = -1
  of pkAnyRune:
    if s[start] != '\0':
      result = runeLenAt(s, start)
    else:
      result = -1
  of pkLetter:
    if s[start] != '\0':
      var a: Rune
      result = start
      fastRuneAt(s, result, a)
      if isAlpha(a): dec(result, start)
      else: result = -1
    else:
      result = -1
  of pkLower:
    if s[start] != '\0':
      var a: Rune
      result = start
      fastRuneAt(s, result, a)
      if isLower(a): dec(result, start)
      else: result = -1
    else:
      result = -1
  of pkUpper:
    if s[start] != '\0':
      var a: Rune
      result = start
      fastRuneAt(s, result, a)
      if isUpper(a): dec(result, start)
      else: result = -1
    else:
      result = -1
  of pkTitle:
    if s[start] != '\0':
      var a: Rune
      result = start
      fastRuneAt(s, result, a)
      if isTitle(a): dec(result, start)
      else: result = -1
    else:
      result = -1
  of pkWhitespace:
    if s[start] != '\0':
      var a: Rune
      result = start
      fastRuneAt(s, result, a)
      if isWhiteSpace(a): dec(result, start)
      else: result = -1
    else:
      result = -1
  of pkGreedyAny:
    result = len(s) - start
  of pkNewLine:
    if s[start] == '\L': result = 1
    elif s[start] == '\C':
      if s[start+1] == '\L': result = 2
      else: result = 1
    else: result = -1
  of pkTerminal:
    result = len(p.term)
    for i in 0..result-1:
      if p.term[i] != s[start+i]:
        result = -1
        break
  of pkTerminalIgnoreCase:
    var
      i = 0
      a, b: Rune
    result = start
    while i < len(p.term):
      fastRuneAt(p.term, i, a)
      fastRuneAt(s, result, b)
      if toLower(a) != toLower(b):
        result = -1
        break
    dec(result, start)
  of pkTerminalIgnoreStyle:
    var
      i = 0
      a, b: Rune
    result = start
    while i < len(p.term):
      while true:
        fastRuneAt(p.term, i, a)
        if a != Rune('_'): break
      while true:
        fastRuneAt(s, result, b)
        if b != Rune('_'): break
      if toLower(a) != toLower(b):
        result = -1
        break
    dec(result, start)
  of pkChar:
    if p.ch == s[start]: result = 1
    else: result = -1
  of pkCharChoice:
    if contains(p.charChoice[], s[start]): result = 1
    else: result = -1
  of pkNonTerminal:
    var oldMl = c.ml
    when false: echo "enter: ", p.nt.name
    result = rawMatch(s, p.nt.rule, start, c)
    when false: echo "leave: ", p.nt.name
    if result < 0: c.ml = oldMl
  of pkSequence:
    var oldMl = c.ml
    result = 0
    for i in 0..high(p.sons):
      var x = rawMatch(s, p.sons[i], start+result, c)
      if x < 0:
        c.ml = oldMl
        result = -1
        break
      else: inc(result, x)
  of pkOrderedChoice:
    var oldMl = c.ml
    for i in 0..high(p.sons):
      result = rawMatch(s, p.sons[i], start, c)
      if result >= 0: break
      c.ml = oldMl
  of pkSearch:
    var oldMl = c.ml
    result = 0
    while start+result < s.len:
      var x = rawMatch(s, p.sons[0], start+result, c)
      if x >= 0:
        inc(result, x)
        return
      inc(result)
    result = -1
    c.ml = oldMl
  of pkCapturedSearch:
    var idx = c.ml # reserve a slot for the subpattern
    inc(c.ml)
    result = 0
    while start+result < s.len:
      var x = rawMatch(s, p.sons[0], start+result, c)
      if x >= 0:
        if idx < MaxSubpatterns:
          c.matches[idx] = (start, start+result-1)
        #else: silently ignore the capture
        inc(result, x)
        return
      inc(result)
    result = -1
    c.ml = idx
  of pkGreedyRep:
    result = 0
    while true:
      var x = rawMatch(s, p.sons[0], start+result, c)
      # if x == 0, we have an endless loop; so the correct behaviour would be
      # not to break. But endless loops can be easily introduced:
      # ``(comment / \w*)*`` is such an example. Breaking for x == 0 does the
      # expected thing in this case.
      if x <= 0: break
      inc(result, x)
  of pkGreedyRepChar:
    result = 0
    var ch = p.ch
    while ch == s[start+result]: inc(result)
  of pkGreedyRepSet:
    result = 0
    while contains(p.charChoice[], s[start+result]): inc(result)
  of pkOption:
    result = max(0, rawMatch(s, p.sons[0], start, c))
  of pkAndPredicate:
    var oldMl = c.ml
    result = rawMatch(s, p.sons[0], start, c)
    if result >= 0: result = 0 # do not consume anything
    else: c.ml = oldMl
  of pkNotPredicate:
    var oldMl = c.ml
    result = rawMatch(s, p.sons[0], start, c)
    if result < 0: result = 0
    else:
      c.ml = oldMl
      result = -1
  of pkCapture:
    var idx = c.ml # reserve a slot for the subpattern
    inc(c.ml)
    result = rawMatch(s, p.sons[0], start, c)
    if result >= 0:
      if idx < MaxSubpatterns:
        c.matches[idx] = (start, start+result-1)
      #else: silently ignore the capture
    else:
      c.ml = idx
  of pkBackRef..pkBackRefIgnoreStyle:
    if p.index >= c.ml: return -1
    var (a, b) = c.matches[p.index]
    var n: Peg
    n.kind = succ(pkTerminal, ord(p.kind)-ord(pkBackRef))
    n.term = s.substr(a, b)
    result = rawMatch(s, n, start, c)
  of pkStartAnchor:
    if c.origStart == start: result = 0
    else: result = -1
  of pkRule, pkList: assert false

template fillMatches(s, caps, c: expr) =
  for k in 0..c.ml-1:
    let startIdx = c.matches[k][0]
    let endIdx = c.matches[k][1]
    if startIdx != -1:
      caps[k] = substr(s, startIdx, endIdx)
    else:
      caps[k] = nil

proc matchLen*(s: string, pattern: Peg, matches: var openArray[string],
               start = 0): int {.nosideEffect, rtl, extern: "npegs$1Capture".} =
  ## the same as ``match``, but it returns the length of the match,
  ## if there is no match, -1 is returned. Note that a match length
  ## of zero can happen. It's possible that a suffix of `s` remains
  ## that does not belong to the match.
  var c: Captures
  c.origStart = start
  result = rawMatch(s, pattern, start, c)
  if result >= 0: fillMatches(s, matches, c)

proc matchLen*(s: string, pattern: Peg,
               start = 0): int {.nosideEffect, rtl, extern: "npegs$1".} =
  ## the same as ``match``, but it returns the length of the match,
  ## if there is no match, -1 is returned. Note that a match length
  ## of zero can happen. It's possible that a suffix of `s` remains
  ## that does not belong to the match.
  var c: Captures
  c.origStart = start
  result = rawMatch(s, pattern, start, c)

proc match*(s: string, pattern: Peg, matches: var openArray[string],
            start = 0): bool {.nosideEffect, rtl, extern: "npegs$1Capture".} =
  ## returns ``true`` if ``s[start..]`` matches the ``pattern`` and
  ## the captured substrings in the array ``matches``. If it does not
  ## match, nothing is written into ``matches`` and ``false`` is
  ## returned.
  result = matchLen(s, pattern, matches, start) != -1

proc match*(s: string, pattern: Peg,
            start = 0): bool {.nosideEffect, rtl, extern: "npegs$1".} =
  ## returns ``true`` if ``s`` matches the ``pattern`` beginning from ``start``.
  result = matchLen(s, pattern, start) != -1


proc find*(s: string, pattern: Peg, matches: var openArray[string],
           start = 0): int {.nosideEffect, rtl, extern: "npegs$1Capture".} =
  ## returns the starting position of ``pattern`` in ``s`` and the captured
  ## substrings in the array ``matches``. If it does not match, nothing
  ## is written into ``matches`` and -1 is returned.
  var c: Captures
  c.origStart = start
  for i in start .. s.len-1:
    c.ml = 0
    if rawMatch(s, pattern, i, c) >= 0:
      fillMatches(s, matches, c)
      return i
  return -1
  # could also use the pattern here: (!P .)* P

proc findBounds*(s: string, pattern: Peg, matches: var openArray[string],
                 start = 0): tuple[first, last: int] {.
                 nosideEffect, rtl, extern: "npegs$1Capture".} =
  ## returns the starting position and end position of ``pattern`` in ``s``
  ## and the captured
  ## substrings in the array ``matches``. If it does not match, nothing
  ## is written into ``matches`` and (-1,0) is returned.
  var c: Captures
  c.origStart = start
  for i in start .. s.len-1:
    c.ml = 0
    var L = rawMatch(s, pattern, i, c)
    if L >= 0:
      fillMatches(s, matches, c)
      return (i, i+L-1)
  return (-1, 0)

proc find*(s: string, pattern: Peg,
           start = 0): int {.nosideEffect, rtl, extern: "npegs$1".} =
  ## returns the starting position of ``pattern`` in ``s``. If it does not
  ## match, -1 is returned.
  var c: Captures
  c.origStart = start
  for i in start .. s.len-1:
    if rawMatch(s, pattern, i, c) >= 0: return i
  return -1

iterator findAll*(s: string, pattern: Peg, start = 0): string =
  ## yields all matching *substrings* of `s` that match `pattern`.
  var c: Captures
  c.origStart = start
  var i = start
  while i < s.len:
    c.ml = 0
    var L = rawMatch(s, pattern, i, c)
    if L < 0:
      inc(i, 1)
    else:
      yield substr(s, i, i+L-1)
      inc(i, L)

proc findAll*(s: string, pattern: Peg, start = 0): seq[string] {.
  nosideEffect, rtl, extern: "npegs$1".} =
  ## returns all matching *substrings* of `s` that match `pattern`.
  ## If it does not match, @[] is returned.
  accumulateResult(findAll(s, pattern, start))

when not defined(nimhygiene):
  {.pragma: inject.}

template `=~`*(s: string, pattern: Peg): bool =
  ## This calls ``match`` with an implicit declared ``matches`` array that
  ## can be used in the scope of the ``=~`` call:
  ##
  ## .. code-block:: nim
  ##
  ##   if line =~ peg"\s* {\w+} \s* '=' \s* {\w+}":
  ##     # matches a key=value pair:
  ##     echo("Key: ", matches[0])
  ##     echo("Value: ", matches[1])
  ##   elif line =~ peg"\s*{'#'.*}":
  ##     # matches a comment
  ##     # note that the implicit ``matches`` array is different from the
  ##     # ``matches`` array of the first branch
  ##     echo("comment: ", matches[0])
  ##   else:
  ##     echo("syntax error")
  ##
  bind MaxSubpatterns
  when not declaredInScope(matches):
    var matches {.inject.}: array[0..MaxSubpatterns-1, string]
  match(s, pattern, matches)

# ------------------------- more string handling ------------------------------

proc contains*(s: string, pattern: Peg, start = 0): bool {.
  nosideEffect, rtl, extern: "npegs$1".} =
  ## same as ``find(s, pattern, start) >= 0``
  return find(s, pattern, start) >= 0

proc contains*(s: string, pattern: Peg, matches: var openArray[string],
              start = 0): bool {.nosideEffect, rtl, extern: "npegs$1Capture".} =
  ## same as ``find(s, pattern, matches, start) >= 0``
  return find(s, pattern, matches, start) >= 0

proc startsWith*(s: string, prefix: Peg, start = 0): bool {.
  nosideEffect, rtl, extern: "npegs$1".} =
  ## returns true if `s` starts with the pattern `prefix`
  result = matchLen(s, prefix, start) >= 0

proc endsWith*(s: string, suffix: Peg, start = 0): bool {.
  nosideEffect, rtl, extern: "npegs$1".} =
  ## returns true if `s` ends with the pattern `prefix`
  var c: Captures
  c.origStart = start
  for i in start .. s.len-1:
    if rawMatch(s, suffix, i, c) == s.len - i: return true

proc replacef*(s: string, sub: Peg, by: string): string {.
  nosideEffect, rtl, extern: "npegs$1".} =
  ## Replaces `sub` in `s` by the string `by`. Captures can be accessed in `by`
  ## with the notation ``$i`` and ``$#`` (see strutils.`%`). Examples:
  ##
  ## .. code-block:: nim
  ##   "var1=key; var2=key2".replacef(peg"{\ident}'='{\ident}", "$1<-$2$2")
  ##
  ## Results in:
  ##
  ## .. code-block:: nim
  ##
  ##   "var1<-keykey; val2<-key2key2"
  result = ""
  var i = 0
  var caps: array[0..MaxSubpatterns-1, string]
  var c: Captures
  while i < s.len:
    c.ml = 0
    var x = rawMatch(s, sub, i, c)
    if x <= 0:
      add(result, s[i])
      inc(i)
    else:
      fillMatches(s, caps, c)
      addf(result, by, caps)
      inc(i, x)
  add(result, substr(s, i))

proc replace*(s: string, sub: Peg, by = ""): string {.
  nosideEffect, rtl, extern: "npegs$1".} =
  ## Replaces `sub` in `s` by the string `by`. Captures cannot be accessed
  ## in `by`.
  result = ""
  var i = 0
  var c: Captures
  while i < s.len:
    var x = rawMatch(s, sub, i, c)
    if x <= 0:
      add(result, s[i])
      inc(i)
    else:
      add(result, by)
      inc(i, x)
  add(result, substr(s, i))

proc parallelReplace*(s: string, subs: varargs[
                      tuple[pattern: Peg, repl: string]]): string {.
                      nosideEffect, rtl, extern: "npegs$1".} =
  ## Returns a modified copy of `s` with the substitutions in `subs`
  ## applied in parallel.
  result = ""
  var i = 0
  var c: Captures
  var caps: array[0..MaxSubpatterns-1, string]
  while i < s.len:
    block searchSubs:
      for j in 0..high(subs):
        c.ml = 0
        var x = rawMatch(s, subs[j][0], i, c)
        if x > 0:
          fillMatches(s, caps, c)
          addf(result, subs[j][1], caps)
          inc(i, x)
          break searchSubs
      add(result, s[i])
      inc(i)
  # copy the rest:
  add(result, substr(s, i))

proc transformFile*(infile, outfile: string,
                    subs: varargs[tuple[pattern: Peg, repl: string]]) {.
                    rtl, extern: "npegs$1".} =
  ## reads in the file `infile`, performs a parallel replacement (calls
  ## `parallelReplace`) and writes back to `outfile`. Raises ``EIO`` if an
  ## error occurs. This is supposed to be used for quick scripting.
  var x = readFile(infile).string
  writeFile(outfile, x.parallelReplace(subs))

iterator split*(s: string, sep: Peg): string =
  ## Splits the string `s` into substrings.
  ##
  ## Substrings are separated by the PEG `sep`.
  ## Examples:
  ##
  ## .. code-block:: nim
  ##   for word in split("00232this02939is39an22example111", peg"\d+"):
  ##     writeLine(stdout, word)
  ##
  ## Results in:
  ##
  ## .. code-block:: nim
  ##   "this"
  ##   "is"
  ##   "an"
  ##   "example"
  ##
  var c: Captures
  var
    first = 0
    last = 0
  while last < len(s):
    c.ml = 0
    var x = rawMatch(s, sep, last, c)
    if x > 0: inc(last, x)
    first = last
    while last < len(s):
      inc(last)
      c.ml = 0
      x = rawMatch(s, sep, last, c)
      if x > 0: break
    if first < last:
      yield substr(s, first, last-1)

proc split*(s: string, sep: Peg): seq[string] {.
  nosideEffect, rtl, extern: "npegs$1".} =
  ## Splits the string `s` into substrings.
  accumulateResult(split(s, sep))

# ------------------- scanner -------------------------------------------------

type
  Modifier = enum
    modNone,
    modVerbatim,
    modIgnoreCase,
    modIgnoreStyle
  TokKind = enum       ## enumeration of all tokens
    tkInvalid,          ## invalid token
    tkEof,              ## end of file reached
    tkAny,              ## .
    tkAnyRune,          ## _
    tkIdentifier,       ## abc
    tkStringLit,        ## "abc" or 'abc'
    tkCharSet,          ## [^A-Z]
    tkParLe,            ## '('
    tkParRi,            ## ')'
    tkCurlyLe,          ## '{'
    tkCurlyRi,          ## '}'
    tkCurlyAt,          ## '{@}'
    tkArrow,            ## '<-'
    tkBar,              ## '/'
    tkStar,             ## '*'
    tkPlus,             ## '+'
    tkAmp,              ## '&'
    tkNot,              ## '!'
    tkOption,           ## '?'
    tkAt,               ## '@'
    tkBuiltin,          ## \identifier
    tkEscaped,          ## \\
    tkBackref,          ## '$'
    tkDollar,           ## '$'
    tkHat               ## '^'

  Token {.final.} = object  ## a token
    kind: TokKind           ## the type of the token
    modifier: Modifier
    literal: string          ## the parsed (string) literal
    charset: set[char]       ## if kind == tkCharSet
    index: int               ## if kind == tkBackref

  PegLexer {.inheritable.} = object          ## the lexer object.
    bufpos: int               ## the current position within the buffer
    buf: cstring              ## the buffer itself
    lineNumber: int           ## the current line number
    lineStart: int            ## index of last line start in buffer
    colOffset: int            ## column to add
    filename: string

const
  tokKindToStr: array[TokKind, string] = [
    "invalid", "[EOF]", ".", "_", "identifier", "string literal",
    "character set", "(", ")", "{", "}", "{@}",
    "<-", "/", "*", "+", "&", "!", "?",
    "@", "built-in", "escaped", "$", "$", "^"
  ]

proc handleCR(L: var PegLexer, pos: int): int =
  assert(L.buf[pos] == '\c')
  inc(L.lineNumber)
  result = pos+1
  if L.buf[result] == '\L': inc(result)
  L.lineStart = result

proc handleLF(L: var PegLexer, pos: int): int =
  assert(L.buf[pos] == '\L')
  inc(L.lineNumber)
  result = pos+1
  L.lineStart = result

proc init(L: var PegLexer, input, filename: string, line = 1, col = 0) =
  L.buf = input
  L.bufpos = 0
  L.lineNumber = line
  L.colOffset = col
  L.lineStart = 0
  L.filename = filename

proc getColumn(L: PegLexer): int {.inline.} =
  result = abs(L.bufpos - L.lineStart) + L.colOffset

proc getLine(L: PegLexer): int {.inline.} =
  result = L.lineNumber

proc errorStr(L: PegLexer, msg: string, line = -1, col = -1): string =
  var line = if line < 0: getLine(L) else: line
  var col = if col < 0: getColumn(L) else: col
  result = "$1($2, $3) Error: $4" % [L.filename, $line, $col, msg]

proc handleHexChar(c: var PegLexer, xi: var int) =
  case c.buf[c.bufpos]
  of '0'..'9':
    xi = (xi shl 4) or (ord(c.buf[c.bufpos]) - ord('0'))
    inc(c.bufpos)
  of 'a'..'f':
    xi = (xi shl 4) or (ord(c.buf[c.bufpos]) - ord('a') + 10)
    inc(c.bufpos)
  of 'A'..'F':
    xi = (xi shl 4) or (ord(c.buf[c.bufpos]) - ord('A') + 10)
    inc(c.bufpos)
  else: discard

proc getEscapedChar(c: var PegLexer, tok: var Token) =
  inc(c.bufpos)
  case c.buf[c.bufpos]
  of 'r', 'R', 'c', 'C':
    add(tok.literal, '\c')
    inc(c.bufpos)
  of 'l', 'L':
    add(tok.literal, '\L')
    inc(c.bufpos)
  of 'f', 'F':
    add(tok.literal, '\f')
    inc(c.bufpos)
  of 'e', 'E':
    add(tok.literal, '\e')
    inc(c.bufpos)
  of 'a', 'A':
    add(tok.literal, '\a')
    inc(c.bufpos)
  of 'b', 'B':
    add(tok.literal, '\b')
    inc(c.bufpos)
  of 'v', 'V':
    add(tok.literal, '\v')
    inc(c.bufpos)
  of 't', 'T':
    add(tok.literal, '\t')
    inc(c.bufpos)
  of 'x', 'X':
    inc(c.bufpos)
    var xi = 0
    handleHexChar(c, xi)
    handleHexChar(c, xi)
    if xi == 0: tok.kind = tkInvalid
    else: add(tok.literal, chr(xi))
  of '0'..'9':
    var val = ord(c.buf[c.bufpos]) - ord('0')
    inc(c.bufpos)
    var i = 1
    while (i <= 3) and (c.buf[c.bufpos] in {'0'..'9'}):
      val = val * 10 + ord(c.buf[c.bufpos]) - ord('0')
      inc(c.bufpos)
      inc(i)
    if val > 0 and val <= 255: add(tok.literal, chr(val))
    else: tok.kind = tkInvalid
  of '\0'..'\31':
    tok.kind = tkInvalid
  elif c.buf[c.bufpos] in strutils.Letters:
    tok.kind = tkInvalid
  else:
    add(tok.literal, c.buf[c.bufpos])
    inc(c.bufpos)

proc skip(c: var PegLexer) =
  var pos = c.bufpos
  var buf = c.buf
  while true:
    case buf[pos]
    of ' ', '\t':
      inc(pos)
    of '#':
      while not (buf[pos] in {'\c', '\L', '\0'}): inc(pos)
    of '\c':
      pos = handleCR(c, pos)
      buf = c.buf
    of '\L':
      pos = handleLF(c, pos)
      buf = c.buf
    else:
      break                   # EndOfFile also leaves the loop
  c.bufpos = pos

proc getString(c: var PegLexer, tok: var Token) =
  tok.kind = tkStringLit
  var pos = c.bufpos + 1
  var buf = c.buf
  var quote = buf[pos-1]
  while true:
    case buf[pos]
    of '\\':
      c.bufpos = pos
      getEscapedChar(c, tok)
      pos = c.bufpos
    of '\c', '\L', '\0':
      tok.kind = tkInvalid
      break
    elif buf[pos] == quote:
      inc(pos)
      break
    else:
      add(tok.literal, buf[pos])
      inc(pos)
  c.bufpos = pos

proc getDollar(c: var PegLexer, tok: var Token) =
  var pos = c.bufpos + 1
  var buf = c.buf
  if buf[pos] in {'0'..'9'}:
    tok.kind = tkBackref
    tok.index = 0
    while buf[pos] in {'0'..'9'}:
      tok.index = tok.index * 10 + ord(buf[pos]) - ord('0')
      inc(pos)
  else:
    tok.kind = tkDollar
  c.bufpos = pos

proc getCharSet(c: var PegLexer, tok: var Token) =
  tok.kind = tkCharSet
  tok.charset = {}
  var pos = c.bufpos + 1
  var buf = c.buf
  var caret = false
  if buf[pos] == '^':
    inc(pos)
    caret = true
  while true:
    var ch: char
    case buf[pos]
    of ']':
      inc(pos)
      break
    of '\\':
      c.bufpos = pos
      getEscapedChar(c, tok)
      pos = c.bufpos
      ch = tok.literal[tok.literal.len-1]
    of '\C', '\L', '\0':
      tok.kind = tkInvalid
      break
    else:
      ch = buf[pos]
      inc(pos)
    incl(tok.charset, ch)
    if buf[pos] == '-':
      if buf[pos+1] == ']':
        incl(tok.charset, '-')
        inc(pos)
      else:
        inc(pos)
        var ch2: char
        case buf[pos]
        of '\\':
          c.bufpos = pos
          getEscapedChar(c, tok)
          pos = c.bufpos
          ch2 = tok.literal[tok.literal.len-1]
        of '\C', '\L', '\0':
          tok.kind = tkInvalid
          break
        else:
          ch2 = buf[pos]
          inc(pos)
        for i in ord(ch)+1 .. ord(ch2):
          incl(tok.charset, chr(i))
  c.bufpos = pos
  if caret: tok.charset = {'\1'..'\xFF'} - tok.charset

proc getSymbol(c: var PegLexer, tok: var Token) =
  var pos = c.bufpos
  var buf = c.buf
  while true:
    add(tok.literal, buf[pos])
    inc(pos)
    if buf[pos] notin strutils.IdentChars: break
  c.bufpos = pos
  tok.kind = tkIdentifier

proc getBuiltin(c: var PegLexer, tok: var Token) =
  if c.buf[c.bufpos+1] in strutils.Letters:
    inc(c.bufpos)
    getSymbol(c, tok)
    tok.kind = tkBuiltin
  else:
    tok.kind = tkEscaped
    getEscapedChar(c, tok) # may set tok.kind to tkInvalid

proc getTok(c: var PegLexer, tok: var Token) =
  tok.kind = tkInvalid
  tok.modifier = modNone
  setLen(tok.literal, 0)
  skip(c)
  case c.buf[c.bufpos]
  of '{':
    inc(c.bufpos)
    if c.buf[c.bufpos] == '@' and c.buf[c.bufpos+1] == '}':
      tok.kind = tkCurlyAt
      inc(c.bufpos, 2)
      add(tok.literal, "{@}")
    else:
      tok.kind = tkCurlyLe
      add(tok.literal, '{')
  of '}':
    tok.kind = tkCurlyRi
    inc(c.bufpos)
    add(tok.literal, '}')
  of '[':
    getCharSet(c, tok)
  of '(':
    tok.kind = tkParLe
    inc(c.bufpos)
    add(tok.literal, '(')
  of ')':
    tok.kind = tkParRi
    inc(c.bufpos)
    add(tok.literal, ')')
  of '.':
    tok.kind = tkAny
    inc(c.bufpos)
    add(tok.literal, '.')
  of '_':
    tok.kind = tkAnyRune
    inc(c.bufpos)
    add(tok.literal, '_')
  of '\\':
    getBuiltin(c, tok)
  of '\'', '"': getString(c, tok)
  of '$': getDollar(c, tok)
  of '\0':
    tok.kind = tkEof
    tok.literal = "[EOF]"
  of 'a'..'z', 'A'..'Z', '\128'..'\255':
    getSymbol(c, tok)
    if c.buf[c.bufpos] in {'\'', '"'} or
        c.buf[c.bufpos] == '$' and c.buf[c.bufpos+1] in {'0'..'9'}:
      case tok.literal
      of "i": tok.modifier = modIgnoreCase
      of "y": tok.modifier = modIgnoreStyle
      of "v": tok.modifier = modVerbatim
      else: discard
      setLen(tok.literal, 0)
      if c.buf[c.bufpos] == '$':
        getDollar(c, tok)
      else:
        getString(c, tok)
      if tok.modifier == modNone: tok.kind = tkInvalid
  of '+':
    tok.kind = tkPlus
    inc(c.bufpos)
    add(tok.literal, '+')
  of '*':
    tok.kind = tkStar
    inc(c.bufpos)
    add(tok.literal, '+')
  of '<':
    if c.buf[c.bufpos+1] == '-':
      inc(c.bufpos, 2)
      tok.kind = tkArrow
      add(tok.literal, "<-")
    else:
      add(tok.literal, '<')
  of '/':
    tok.kind = tkBar
    inc(c.bufpos)
    add(tok.literal, '/')
  of '?':
    tok.kind = tkOption
    inc(c.bufpos)
    add(tok.literal, '?')
  of '!':
    tok.kind = tkNot
    inc(c.bufpos)
    add(tok.literal, '!')
  of '&':
    tok.kind = tkAmp
    inc(c.bufpos)
    add(tok.literal, '!')
  of '@':
    tok.kind = tkAt
    inc(c.bufpos)
    add(tok.literal, '@')
    if c.buf[c.bufpos] == '@':
      tok.kind = tkCurlyAt
      inc(c.bufpos)
      add(tok.literal, '@')
  of '^':
    tok.kind = tkHat
    inc(c.bufpos)
    add(tok.literal, '^')
  else:
    add(tok.literal, c.buf[c.bufpos])
    inc(c.bufpos)

proc arrowIsNextTok(c: PegLexer): bool =
  # the only look ahead we need
  var pos = c.bufpos
  while c.buf[pos] in {'\t', ' '}: inc(pos)
  result = c.buf[pos] == '<' and c.buf[pos+1] == '-'

# ----------------------------- parser ----------------------------------------

type
  EInvalidPeg* = object of ValueError ## raised if an invalid
                                         ## PEG has been detected
  PegParser = object of PegLexer ## the PEG parser object
    tok: Token
    nonterms: seq[NonTerminal]
    modifier: Modifier
    captures: int
    identIsVerbatim: bool
    skip: Peg

proc pegError(p: PegParser, msg: string, line = -1, col = -1) =
  var e: ref EInvalidPeg
  new(e)
  e.msg = errorStr(p, msg, line, col)
  raise e

proc getTok(p: var PegParser) =
  getTok(p, p.tok)
  if p.tok.kind == tkInvalid: pegError(p, "invalid token")

proc eat(p: var PegParser, kind: TokKind) =
  if p.tok.kind == kind: getTok(p)
  else: pegError(p, tokKindToStr[kind] & " expected")

proc parseExpr(p: var PegParser): Peg {.gcsafe.}

proc getNonTerminal(p: var PegParser, name: string): NonTerminal =
  for i in 0..high(p.nonterms):
    result = p.nonterms[i]
    if cmpIgnoreStyle(result.name, name) == 0: return
  # forward reference:
  result = newNonTerminal(name, getLine(p), getColumn(p))
  add(p.nonterms, result)

proc modifiedTerm(s: string, m: Modifier): Peg =
  case m
  of modNone, modVerbatim: result = term(s)
  of modIgnoreCase: result = termIgnoreCase(s)
  of modIgnoreStyle: result = termIgnoreStyle(s)

proc modifiedBackref(s: int, m: Modifier): Peg =
  case m
  of modNone, modVerbatim: result = backref(s)
  of modIgnoreCase: result = backrefIgnoreCase(s)
  of modIgnoreStyle: result = backrefIgnoreStyle(s)

proc builtin(p: var PegParser): Peg =
  # do not use "y", "skip" or "i" as these would be ambiguous
  case p.tok.literal
  of "n": result = newLine()
  of "d": result = charSet({'0'..'9'})
  of "D": result = charSet({'\1'..'\xff'} - {'0'..'9'})
  of "s": result = charSet({' ', '\9'..'\13'})
  of "S": result = charSet({'\1'..'\xff'} - {' ', '\9'..'\13'})
  of "w": result = charSet({'a'..'z', 'A'..'Z', '_', '0'..'9'})
  of "W": result = charSet({'\1'..'\xff'} - {'a'..'z','A'..'Z','_','0'..'9'})
  of "a": result = charSet({'a'..'z', 'A'..'Z'})
  of "A": result = charSet({'\1'..'\xff'} - {'a'..'z', 'A'..'Z'})
  of "ident": result = pegs.ident
  of "letter": result = unicodeLetter()
  of "upper": result = unicodeUpper()
  of "lower": result = unicodeLower()
  of "title": result = unicodeTitle()
  of "white": result = unicodeWhitespace()
  else: pegError(p, "unknown built-in: " & p.tok.literal)

proc token(terminal: Peg, p: PegParser): Peg =
  if p.skip.kind == pkEmpty: result = terminal
  else: result = sequence(p.skip, terminal)

proc primary(p: var PegParser): Peg =
  case p.tok.kind
  of tkAmp:
    getTok(p)
    return &primary(p)
  of tkNot:
    getTok(p)
    return !primary(p)
  of tkAt:
    getTok(p)
    return !*primary(p)
  of tkCurlyAt:
    getTok(p)
    return !*\primary(p).token(p)
  else: discard
  case p.tok.kind
  of tkIdentifier:
    if p.identIsVerbatim:
      var m = p.tok.modifier
      if m == modNone: m = p.modifier
      result = modifiedTerm(p.tok.literal, m).token(p)
      getTok(p)
    elif not arrowIsNextTok(p):
      var nt = getNonTerminal(p, p.tok.literal)
      incl(nt.flags, ntUsed)
      result = nonterminal(nt).token(p)
      getTok(p)
    else:
      pegError(p, "expression expected, but found: " & p.tok.literal)
  of tkStringLit:
    var m = p.tok.modifier
    if m == modNone: m = p.modifier
    result = modifiedTerm(p.tok.literal, m).token(p)
    getTok(p)
  of tkCharSet:
    if '\0' in p.tok.charset:
      pegError(p, "binary zero ('\\0') not allowed in character class")
    result = charSet(p.tok.charset).token(p)
    getTok(p)
  of tkParLe:
    getTok(p)
    result = parseExpr(p)
    eat(p, tkParRi)
  of tkCurlyLe:
    getTok(p)
    result = capture(parseExpr(p)).token(p)
    eat(p, tkCurlyRi)
    inc(p.captures)
  of tkAny:
    result = any().token(p)
    getTok(p)
  of tkAnyRune:
    result = anyRune().token(p)
    getTok(p)
  of tkBuiltin:
    result = builtin(p).token(p)
    getTok(p)
  of tkEscaped:
    result = term(p.tok.literal[0]).token(p)
    getTok(p)
  of tkDollar:
    result = endAnchor()
    getTok(p)
  of tkHat:
    result = startAnchor()
    getTok(p)
  of tkBackref:
    var m = p.tok.modifier
    if m == modNone: m = p.modifier
    result = modifiedBackref(p.tok.index, m).token(p)
    if p.tok.index < 0 or p.tok.index > p.captures:
      pegError(p, "invalid back reference index: " & $p.tok.index)
    getTok(p)
  else:
    pegError(p, "expression expected, but found: " & p.tok.literal)
    getTok(p) # we must consume a token here to prevent endless loops!
  while true:
    case p.tok.kind
    of tkOption:
      result = ?result
      getTok(p)
    of tkStar:
      result = *result
      getTok(p)
    of tkPlus:
      result = +result
      getTok(p)
    else: break

proc seqExpr(p: var PegParser): Peg =
  result = primary(p)
  while true:
    case p.tok.kind
    of tkAmp, tkNot, tkAt, tkStringLit, tkCharSet, tkParLe, tkCurlyLe,
       tkAny, tkAnyRune, tkBuiltin, tkEscaped, tkDollar, tkBackref,
       tkHat, tkCurlyAt:
      result = sequence(result, primary(p))
    of tkIdentifier:
      if not arrowIsNextTok(p):
        result = sequence(result, primary(p))
      else: break
    else: break

proc parseExpr(p: var PegParser): Peg =
  result = seqExpr(p)
  while p.tok.kind == tkBar:
    getTok(p)
    result = result / seqExpr(p)

proc parseRule(p: var PegParser): NonTerminal =
  if p.tok.kind == tkIdentifier and arrowIsNextTok(p):
    result = getNonTerminal(p, p.tok.literal)
    if ntDeclared in result.flags:
      pegError(p, "attempt to redefine: " & result.name)
    result.line = getLine(p)
    result.col = getColumn(p)
    getTok(p)
    eat(p, tkArrow)
    result.rule = parseExpr(p)
    incl(result.flags, ntDeclared) # NOW inlining may be attempted
  else:
    pegError(p, "rule expected, but found: " & p.tok.literal)

proc rawParse(p: var PegParser): Peg =
  ## parses a rule or a PEG expression
  while p.tok.kind == tkBuiltin:
    case p.tok.literal
    of "i":
      p.modifier = modIgnoreCase
      getTok(p)
    of "y":
      p.modifier = modIgnoreStyle
      getTok(p)
    of "skip":
      getTok(p)
      p.skip = ?primary(p)
    else: break
  if p.tok.kind == tkIdentifier and arrowIsNextTok(p):
    result = parseRule(p).rule
    while p.tok.kind != tkEof:
      discard parseRule(p)
  else:
    p.identIsVerbatim = true
    result = parseExpr(p)
  if p.tok.kind != tkEof:
    pegError(p, "EOF expected, but found: " & p.tok.literal)
  for i in 0..high(p.nonterms):
    var nt = p.nonterms[i]
    if ntDeclared notin nt.flags:
      pegError(p, "undeclared identifier: " & nt.name, nt.line, nt.col)
    elif ntUsed notin nt.flags and i > 0:
      pegError(p, "unused rule: " & nt.name, nt.line, nt.col)

proc parsePeg*(pattern: string, filename = "pattern", line = 1, col = 0): Peg =
  ## constructs a Peg object from `pattern`. `filename`, `line`, `col` are
  ## used for error messages, but they only provide start offsets. `parsePeg`
  ## keeps track of line and column numbers within `pattern`.
  var p: PegParser
  init(PegLexer(p), pattern, filename, line, col)
  p.tok.kind = tkInvalid
  p.tok.modifier = modNone
  p.tok.literal = ""
  p.tok.charset = {}
  p.nonterms = @[]
  p.identIsVerbatim = false
  getTok(p)
  result = rawParse(p)

proc peg*(pattern: string): Peg =
  ## constructs a Peg object from the `pattern`. The short name has been
  ## chosen to encourage its use as a raw string modifier::
  ##
  ##   peg"{\ident} \s* '=' \s* {.*}"
  result = parsePeg(pattern, "pattern")

proc escapePeg*(s: string): string =
  ## escapes `s` so that it is matched verbatim when used as a peg.
  result = ""
  var inQuote = false
  for c in items(s):
    case c
    of '\0'..'\31', '\'', '"', '\\':
      if inQuote:
        result.add('\'')
        inQuote = false
      result.add("\\x")
      result.add(toHex(ord(c), 2))
    else:
      if not inQuote:
        result.add('\'')
        inQuote = true
      result.add(c)
  if inQuote: result.add('\'')

when isMainModule:
  assert escapePeg("abc''def'") == r"'abc'\x27\x27'def'\x27"
  assert match("(a b c)", peg"'(' @ ')'")
  assert match("W_HI_Le", peg"\y 'while'")
  assert(not match("W_HI_L", peg"\y 'while'"))
  assert(not match("W_HI_Le", peg"\y v'while'"))
  assert match("W_HI_Le", peg"y'while'")

  assert($ +digits == $peg"\d+")
  assert "0158787".match(peg"\d+")
  assert "ABC 0232".match(peg"\w+\s+\d+")
  assert "ABC".match(peg"\d+ / \w+")

  var accum: seq[string] = @[]
  for word in split("00232this02939is39an22example111", peg"\d+"):
    accum.add(word)
  assert(accum == @["this", "is", "an", "example"])

  assert matchLen("key", ident) == 3

  var pattern = sequence(ident, *whitespace, term('='), *whitespace, ident)
  assert matchLen("key1=  cal9", pattern) == 11

  var ws = newNonTerminal("ws", 1, 1)
  ws.rule = *whitespace

  var expr = newNonTerminal("expr", 1, 1)
  expr.rule = sequence(capture(ident), *sequence(
                nonterminal(ws), term('+'), nonterminal(ws), nonterminal(expr)))

  var c: Captures
  var s = "a+b +  c +d+e+f"
  assert rawMatch(s, expr.rule, 0, c) == len(s)
  var a = ""
  for i in 0..c.ml-1:
    a.add(substr(s, c.matches[i][0], c.matches[i][1]))
  assert a == "abcdef"
  #echo expr.rule

  #const filename = "lib/devel/peg/grammar.txt"
  #var grammar = parsePeg(newFileStream(filename, fmRead), filename)
  #echo "a <- [abc]*?".match(grammar)
  assert find("_____abc_______", term("abc"), 2) == 5
  assert match("_______ana", peg"A <- 'ana' / . A")
  assert match("abcs%%%", peg"A <- ..A / .A / '%'")

  var matches: array[0..MaxSubpatterns-1, string]
  if "abc" =~ peg"{'a'}'bc' 'xyz' / {\ident}":
    assert matches[0] == "abc"
  else:
    assert false

  var g2 = peg"""S <- A B / C D
                 A <- 'a'+
                 B <- 'b'+
                 C <- 'c'+
                 D <- 'd'+
              """
  assert($g2 == "((A B) / (C D))")
  assert match("cccccdddddd", g2)
  assert("var1=key; var2=key2".replacef(peg"{\ident}'='{\ident}", "$1<-$2$2") ==
         "var1<-keykey; var2<-key2key2")
  assert("var1=key; var2=key2".replace(peg"{\ident}'='{\ident}", "$1<-$2$2") ==
         "$1<-$2$2; $1<-$2$2")
  assert "var1=key; var2=key2".endsWith(peg"{\ident}'='{\ident}")

  if "aaaaaa" =~ peg"'aa' !. / ({'a'})+":
    assert matches[0] == "a"
  else:
    assert false

  if match("abcdefg", peg"c {d} ef {g}", matches, 2):
    assert matches[0] == "d"
    assert matches[1] == "g"
  else:
    assert false

  accum = @[]
  for x in findAll("abcdef", peg".", 3):
    accum.add(x)
  assert(accum == @["d", "e", "f"])

  for x in findAll("abcdef", peg"^{.}", 3):
    assert x == "d"

  if "f(a, b)" =~ peg"{[0-9]+} / ({\ident} '(' {@} ')')":
    assert matches[0] == "f"
    assert matches[1] == "a, b"
  else:
    assert false

  assert match("eine übersicht und außerdem", peg"(\letter \white*)+")
  # ß is not a lower cased letter?!
  assert match("eine übersicht und auerdem", peg"(\lower \white*)+")
  assert match("EINE ÜBERSICHT UND AUSSERDEM", peg"(\upper \white*)+")
  assert(not match("456678", peg"(\letter)+"))

  assert("var1 = key; var2 = key2".replacef(
    peg"\skip(\s*) {\ident}'='{\ident}", "$1<-$2$2") ==
         "var1<-keykey;var2<-key2key2")

  assert match("prefix/start", peg"^start$", 7)

  if "foo" =~ peg"{'a'}?.*":
    assert matches[0] == nil
  else: assert false

  if "foo" =~ peg"{''}.*":
    assert matches[0] == ""
  else: assert false

  if "foo" =~ peg"{'foo'}":
    assert matches[0] == "foo"
  else: assert false

  let empty_test = peg"^\d*"
  let str = "XYZ"

  assert(str.find(empty_test) == 0)
  assert(str.match(empty_test))

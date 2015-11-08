#
#            Nim's Runtime Library
#        (c) Copyright 2015 Nim Contributers
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.
#


from pcre import nil
import nre.private.util
import tables
import unsigned
from strutils import toLower, `%`
from math import ceil
import options
from unicode import runeLenAt


## What is NRE?
## ============
##
## A regular expression library for Nim using PCRE to do the hard work.
##
## Licencing
## ---------
##
## PCRE has some additional terms that you must comply with if you use this module.::
##
## > Copyright (c) 1997-2001 University of Cambridge
## >
## > Permission is granted to anyone to use this software for any purpose on any
## > computer system, and to redistribute it freely, subject to the following
## > restrictions:
## >
## > 1. This software is distributed in the hope that it will be useful,
## >    but WITHOUT ANY WARRANTY; without even the implied warranty of
## >    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.
## >
## > 2. The origin of this software must not be misrepresented, either by
## >    explicit claim or by omission. In practice, this means that if you use
## >    PCRE in software that you distribute to others, commercially or
## >    otherwise, you must put a sentence like this
## >
## >      Regular expression support is provided by the PCRE library package,
## >      which is open source software, written by Philip Hazel, and copyright
## >      by the University of Cambridge, England.
## >
## >    somewhere reasonably visible in your documentation and in any relevant
## >    files or online help data or similar. A reference to the ftp site for
## >    the source, that is, to
## >
## >      ftp://ftp.csx.cam.ac.uk/pub/software/programming/pcre/
## >
## >    should also be given in the documentation. However, this condition is not
## >    intended to apply to whole chains of software. If package A includes PCRE,
## >    it must acknowledge it, but if package B is software that includes package
## >    A, the condition is not imposed on package B (unless it uses PCRE
## >    independently).
## >
## > 3. Altered versions must be plainly marked as such, and must not be
## >    misrepresented as being the original software.
## >
## > 4. If PCRE is embedded in any software that is released under the GNU
## >    General Purpose Licence (GPL), or Lesser General Purpose Licence (LGPL),
## >    then the terms of that licence shall supersede any condition above with
## >    which it is incompatible.


# Type definitions {{{
type
  Regex* = ref object
    ## Represents the pattern that things are matched against, constructed with
    ## ``re(string)``. Examples: ``re"foo"``, ``re(r"(*ANYCRLF)(?x)foo #
    ## comment".``
    ##
    ## ``pattern: string``
    ##     the string that was used to create the pattern.
    ##
    ## ``captureCount: int``
    ##     the number of captures that the pattern has.
    ##
    ## ``captureNameId: Table[string, int]``
    ##     a table from the capture names to their numeric id.
    ##
    ##
    ## Options
    ## .......
    ##
    ## The following options may appear anywhere in the pattern, and they affect
    ## the rest of it.
    ##
    ## -  ``(?i)`` - case insensitive
    ## -  ``(?m)`` - multi-line: ``^`` and ``$`` match the beginning and end of
    ##    lines, not of the subject string
    ## -  ``(?s)`` - ``.`` also matches newline (*dotall*)
    ## -  ``(?U)`` - expressions are not greedy by default. ``?`` can be added
    ##    to a qualifier to make it greedy
    ## -  ``(?x)`` - whitespace and comments (``#``) are ignored (*extended*)
    ## -  ``(?X)`` - character escapes without special meaning (``\w`` vs.
    ##    ``\a``) are errors (*extra*)
    ##
    ## One or a combination of these options may appear only at the beginning
    ## of the pattern:
    ##
    ## -  ``(*UTF8)`` - treat both the pattern and subject as UTF-8
    ## -  ``(*UCP)`` - Unicode character properties; ``\w`` matches ``я``
    ## -  ``(*U)`` - a combination of the two options above
    ## -  ``(*FIRSTLINE*)`` - fails if there is not a match on the first line
    ## -  ``(*NO_AUTO_CAPTURE)`` - turn off auto-capture for groups;
    ##    ``(?<name>...)`` can be used to capture
    ## -  ``(*CR)`` - newlines are separated by ``\r``
    ## -  ``(*LF)`` - newlines are separated by ``\n`` (UNIX default)
    ## -  ``(*CRLF)`` - newlines are separated by ``\r\n`` (Windows default)
    ## -  ``(*ANYCRLF)`` - newlines are separated by any of the above
    ## -  ``(*ANY)`` - newlines are separated by any of the above and Unicode
    ##    newlines:
    ##
    ##     single characters VT (vertical tab, U+000B), FF (form feed, U+000C),
    ##     NEL (next line, U+0085), LS (line separator, U+2028), and PS
    ##     (paragraph separator, U+2029). For the 8-bit library, the last two
    ##     are recognized only in UTF-8 mode.
    ##     —  man pcre
    ##
    ## -  ``(*JAVASCRIPT_COMPAT)`` - JavaScript compatibility
    ## -  ``(*NO_STUDY)`` - turn off studying; study is enabled by default
    ##
    ## For more details on the leading option groups, see the `Option
    ## Setting <http://man7.org/linux/man-pages/man3/pcresyntax.3.html#OPTION_SETTING>`__
    ## and the `Newline
    ## Convention <http://man7.org/linux/man-pages/man3/pcresyntax.3.html#NEWLINE_CONVENTION>`__
    ## sections of the `PCRE syntax
    ## manual <http://man7.org/linux/man-pages/man3/pcresyntax.3.html>`__.
    pattern*: string  ## not nil
    pcreObj: ptr pcre.Pcre  ## not nil
    pcreExtra: ptr pcre.ExtraData  ## nil

    captureNameToId: Table[string, int]

  RegexMatch* = object
    ## Usually seen as Option[RegexMatch], it represents the result of an
    ## execution. On failure, it is none, on success, it is some.
    ##
    ## ``pattern: Regex``
    ##     the pattern that is being matched
    ##
    ## ``str: string``
    ##     the string that was matched against
    ##
    ## ``captures[]: string``
    ##     the string value of whatever was captured at that id. If the value
    ##     is invalid, then behavior is undefined. If the id is ``-1``, then
    ##     the whole match is returned. If the given capture was not matched,
    ##     ``nil`` is returned.
    ##
    ##     -  ``"abc".match(re"(\w)").captures[0] == "a"``
    ##     -  ``"abc".match(re"(?<letter>\w)").captures["letter"] == "a"``
    ##     -  ``"abc".match(re"(\w)\w").captures[-1] == "ab"``
    ##
    ## ``captureBounds[]: Option[Slice[int]]``
    ##     gets the bounds of the given capture according to the same rules as
    ##     the above. If the capture is not filled, then ``None`` is returned.
    ##     The bounds are both inclusive.
    ##
    ##     -  ``"abc".match(re"(\w)").captureBounds[0] == 0 .. 0``
    ##     -  ``"abc".match(re"").captureBounds[-1] == 0 .. -1``
    ##     -  ``"abc".match(re"abc").captureBounds[-1] == 0 .. 2``
    ##
    ## ``match: string``
    ##     the full text of the match.
    ##
    ## ``matchBounds: Slice[int]``
    ##     the bounds of the match, as in ``captureBounds[]``
    ##
    ## ``(captureBounds|captures).toTable``
    ##     returns a table with each named capture as a key.
    ##
    ## ``(captureBounds|captures).toSeq``
    ##     returns all the captures by their number.
    ##
    ## ``$: string``
    ##     same as ``match``
    pattern*: Regex  ## The regex doing the matching.
                     ## Not nil.
    str*: string  ## The string that was matched against.
                  ## Not nil.
    pcreMatchBounds: seq[Slice[cint]] ## First item is the bounds of the match
                                      ## Other items are the captures
                                      ## `a` is inclusive start, `b` is exclusive end

  Captures* = distinct RegexMatch
  CaptureBounds* = distinct RegexMatch

  RegexError* = ref object of Exception

  RegexInternalError* = ref object of RegexError
    ## Internal error in the module, this probably means that there is a bug

  InvalidUnicodeError* = ref object of RegexError
    ## Thrown when matching fails due to invalid unicode in strings
    pos*: int  ## the location of the invalid unicode in bytes

  SyntaxError* = ref object of RegexError
    ## Thrown when there is a syntax error in the
    ## regular expression string passed in
    pos*: int  ## the location of the syntax error in bytes
    pattern*: string  ## the pattern that caused the problem

  StudyError* = ref object of RegexError
    ## Thrown when studying the regular expression failes
    ## for whatever reason. The message contains the error
    ## code.
# }}}

proc getinfo[T](pattern: Regex, opt: cint): T =
  let retcode = pcre.fullinfo(pattern.pcreObj, pattern.pcreExtra, opt, addr result)

  if retcode < 0:
    # XXX Error message that doesn't expose implementation details
    raise newException(FieldError, "Invalid getinfo for $1, errno $2" % [$opt, $retcode])

# Regex accessors {{{
proc captureCount*(pattern: Regex): int =
  return getinfo[cint](pattern, pcre.INFO_CAPTURECOUNT)

proc captureNameId*(pattern: Regex): Table[string, int] =
  return pattern.captureNameToId

proc matchesCrLf(pattern: Regex): bool =
  let flags = uint32(getinfo[culong](pattern, pcre.INFO_OPTIONS))
  let newlineFlags = flags and (pcre.NEWLINE_CRLF or
                                pcre.NEWLINE_ANY or
                                pcre.NEWLINE_ANYCRLF)
  if newLineFlags > 0u32:
    return true

  # get flags from build config
  var confFlags: cint
  if pcre.config(pcre.CONFIG_NEWLINE, addr confFlags) != 0:
    assert(false, "CONFIG_NEWLINE apparently got screwed up")

  case confFlags
  of 13: return false
  of 10: return false
  of (13 shl 8) or 10: return true
  of -2: return true
  of -1: return true
  else: return false
# }}}

# Capture accessors {{{
proc captureBounds*(pattern: RegexMatch): CaptureBounds = return CaptureBounds(pattern)

proc captures*(pattern: RegexMatch): Captures = return Captures(pattern)

proc `[]`*(pattern: CaptureBounds, i: int): Option[Slice[int]] =
  let pattern = RegexMatch(pattern)
  if pattern.pcreMatchBounds[i + 1].a != -1:
    let bounds = pattern.pcreMatchBounds[i + 1]
    return some(int(bounds.a) .. int(bounds.b-1))
  else:
    return none(Slice[int])

proc `[]`*(pattern: Captures, i: int): string =
  let pattern = RegexMatch(pattern)
  let bounds = pattern.captureBounds[i]

  if bounds.isSome:
    let bounds = bounds.get
    return pattern.str.substr(bounds.a, bounds.b)
  else:
    return nil

proc match*(pattern: RegexMatch): string =
  return pattern.captures[-1]

proc matchBounds*(pattern: RegexMatch): Slice[int] =
  return pattern.captureBounds[-1].get

proc `[]`*(pattern: CaptureBounds, name: string): Option[Slice[int]] =
  let pattern = RegexMatch(pattern)
  return pattern.captureBounds[pattern.pattern.captureNameToId.fget(name)]

proc `[]`*(pattern: Captures, name: string): string =
  let pattern = RegexMatch(pattern)
  return pattern.captures[pattern.pattern.captureNameToId.fget(name)]

template toTableImpl(cond: bool): stmt {.immediate, dirty.} =
  for key in RegexMatch(pattern).pattern.captureNameId.keys:
    let nextVal = pattern[key]
    if cond:
      result[key] = default
    else:
      result[key] = nextVal

proc toTable*(pattern: Captures, default: string = nil): Table[string, string] =
  result = initTable[string, string]()
  toTableImpl(nextVal == nil)

proc toTable*(pattern: CaptureBounds, default = none(Slice[int])):
    Table[string, Option[Slice[int]]] =
  result = initTable[string, Option[Slice[int]]]()
  toTableImpl(nextVal.isNone)

template itemsImpl(cond: bool): stmt {.immediate, dirty.} =
  for i in 0 .. <RegexMatch(pattern).pattern.captureCount:
    let nextVal = pattern[i]
    # done in this roundabout way to avoid multiple yields (potential code
    # bloat)
    let nextYieldVal = if cond: default else: nextVal
    yield nextYieldVal


iterator items*(pattern: CaptureBounds, default = none(Slice[int])): Option[Slice[int]] =
  itemsImpl(nextVal.isNone)

iterator items*(pattern: Captures, default: string = nil): string =
  itemsImpl(nextVal == nil)

proc toSeq*(pattern: CaptureBounds, default = none(Slice[int])): seq[Option[Slice[int]]] =
  accumulateResult(pattern.items(default))

proc toSeq*(pattern: Captures, default: string = nil): seq[string] =
  accumulateResult(pattern.items(default))

proc `$`*(pattern: RegexMatch): string =
  return pattern.captures[-1]

proc `==`*(a, b: Regex): bool =
  if not a.isNil and not b.isNil:
    return a.pattern   == b.pattern and
           a.pcreObj   == b.pcreObj and
           a.pcreExtra == b.pcreExtra
  else:
    return system.`==`(a, b)

proc `==`*(a, b: RegexMatch): bool =
  return a.pattern == b.pattern and
         a.str     == b.str
# }}}

# Creation & Destruction {{{
# PCRE Options {{{
const PcreOptions = {
  "NEVER_UTF": pcre.NEVER_UTF,
  "ANCHORED": pcre.ANCHORED,
  "DOLLAR_ENDONLY": pcre.DOLLAR_ENDONLY,
  "FIRSTLINE": pcre.FIRSTLINE,
  "NO_AUTO_CAPTURE": pcre.NO_AUTO_CAPTURE,
  "JAVASCRIPT_COMPAT": pcre.JAVASCRIPT_COMPAT,
  "U": pcre.UTF8 or pcre.UCP
}.toTable

# Options that are supported inside regular expressions themselves
const SkipOptions = [
  "LIMIT_MATCH=", "LIMIT_RECURSION=", "NO_AUTO_POSSESS", "NO_START_OPT",
  "UTF8", "UTF16", "UTF32", "UTF", "UCP",
  "CR", "LF", "CRLF", "ANYCRLF", "ANY", "BSR_ANYCRLF", "BSR_UNICODE"
]

proc extractOptions(pattern: string): tuple[pattern: string, flags: int, study: bool] =
  result = ("", 0, true)

  var optionStart = 0
  var equals = false
  for i, c in pattern:
    if optionStart == i:
      if c != '(':
        break
      optionStart = i

    elif optionStart == i-1:
      if c != '*':
        break

    elif c == ')':
      let name = pattern[optionStart+2 .. i-1]
      if equals or name in SkipOptions:
        result.pattern.add pattern[optionStart .. i]
      elif PcreOptions.hasKey name:
        result.flags = result.flags or PcreOptions[name]
      elif name == "NO_STUDY":
        result.study = false
      else:
        break
      optionStart = i+1
      equals = false

    elif not equals:
      if c == '=':
        equals = true
        if pattern[optionStart+2 .. i] notin SkipOptions:
          break
      elif c notin {'A'..'Z', '0'..'9', '_'}:
        break

  result.pattern.add pattern[optionStart .. pattern.high]

# }}}

type UncheckedArray {.unchecked.}[T] = array[0 .. 0, T]

proc destroyRegex(pattern: Regex) =
  pcre.free_substring(cast[cstring](pattern.pcreObj))
  pattern.pcreObj = nil
  if pattern.pcreExtra != nil:
    pcre.free_study(pattern.pcreExtra)

proc getNameToNumberTable(pattern: Regex): Table[string, int] =
  let entryCount = getinfo[cint](pattern, pcre.INFO_NAMECOUNT)
  let entrySize = getinfo[cint](pattern, pcre.INFO_NAMEENTRYSIZE)
  let table = cast[ptr UncheckedArray[uint8]](
                getinfo[int](pattern, pcre.INFO_NAMETABLE))

  result = initTable[string, int]()

  for i in 0 .. <entryCount:
    let pos = i * entrySize
    let num = (int(table[pos]) shl 8) or int(table[pos + 1]) - 1
    var name = ""

    var idx = 2
    while table[pos + idx] != 0:
      name.add(char(table[pos + idx]))
      idx += 1

    result[name] = num

proc initRegex(pattern: string, flags: int, study = true): Regex =
  new(result, destroyRegex)
  result.pattern = pattern

  var errorMsg: cstring
  var errOffset: cint

  result.pcreObj = pcre.compile(cstring(pattern),
                                # better hope int is at least 4 bytes..
                                cint(flags), addr errorMsg,
                                addr errOffset, nil)
  if result.pcreObj == nil:
    # failed to compile
    raise SyntaxError(msg: $errorMsg, pos: errOffset, pattern: pattern)

  if study:
    # XXX investigate JIT
    result.pcreExtra = pcre.study(result.pcreObj, 0x0, addr errorMsg)
    if errorMsg != nil:
      raise StudyError(msg: $errorMsg)

  result.captureNameToId = result.getNameToNumberTable()

proc re*(pattern: string): Regex =
  let (pattern, flags, study) = extractOptions(pattern)
  initRegex(pattern, flags, study)
# }}}

# Operations {{{
proc matchImpl(str: string, pattern: Regex, start, endpos: int, flags: int): Option[RegexMatch] =
  var myResult = RegexMatch(pattern : pattern, str : str)
  # See PCRE man pages.
  # 2x capture count to make room for start-end pairs
  # 1x capture count as slack space for PCRE
  let vecsize = (pattern.captureCount() + 1) * 3
  # div 2 because each element is 2 cints long
  myResult.pcreMatchBounds = newSeq[Slice[cint]](ceil(vecsize / 2).int)
  myResult.pcreMatchBounds.setLen(vecsize div 3)

  let strlen = if endpos == int.high: str.len else: endpos+1
  doAssert(strlen <= str.len)  # don't want buffer overflows

  let execRet = pcre.exec(pattern.pcreObj,
                          pattern.pcreExtra,
                          cstring(str),
                          cint(strlen),
                          cint(start),
                          cint(flags),
                          cast[ptr cint](addr myResult.pcreMatchBounds[0]),
                          cint(vecsize))
  if execRet >= 0:
    return some(myResult)

  case execRet:
    of pcre.ERROR_NOMATCH:
      return none(RegexMatch)
    of pcre.ERROR_NULL:
      raise newException(AccessViolationError, "Expected non-null parameters")
    of pcre.ERROR_BADOPTION:
      raise RegexInternalError(msg : "Unknown pattern flag. Either a bug or " &
        "outdated PCRE.")
    of pcre.ERROR_BADUTF8, pcre.ERROR_SHORTUTF8, pcre.ERROR_BADUTF8_OFFSET:
      raise InvalidUnicodeError(msg : "Invalid unicode byte sequence",
        pos : myResult.pcreMatchBounds[0].a)
    else:
      raise RegexInternalError(msg : "Unknown internal error: " & $execRet)

proc match*(str: string, pattern: Regex, start = 0, endpos = int.high): Option[RegexMatch] =
  ## Like ```find(...)`` <#proc-find>`__, but anchored to the start of the
  ## string. This means that ``"foo".match(re"f") == true``, but
  ## ``"foo".match(re"o") == false``.
  return str.matchImpl(pattern, start, endpos, pcre.ANCHORED)

iterator findIter*(str: string, pattern: Regex, start = 0, endpos = int.high): RegexMatch =
  ## Works the same as ```find(...)`` <#proc-find>`__, but finds every
  ## non-overlapping match. ``"2222".find(re"22")`` is ``"22", "22"``, not
  ## ``"22", "22", "22"``.
  ##
  ## Arguments are the same as ```find(...)`` <#proc-find>`__
  ##
  ## Variants:
  ##
  ## -  ``proc findAll(...)`` returns a ``seq[string]``
  # see pcredemo for explaination
  let matchesCrLf = pattern.matchesCrLf()
  let unicode = uint32(getinfo[culong](pattern, pcre.INFO_OPTIONS) and
    pcre.UTF8) > 0u32
  let strlen = if endpos == int.high: str.len else: endpos+1

  var offset = start
  var match: Option[RegexMatch]
  while true:
    var flags = 0

    if match.isSome and
       match.get.matchBounds.a > match.get.matchBounds.b:
      # 0-len match
      flags = pcre.NOTEMPTY_ATSTART

    match = str.matchImpl(pattern, offset, endpos, flags)

    if match.isNone:
      # either the end of the input or the string
      # cannot be split here
      if offset >= strlen:
        break

      if matchesCrLf and offset < (str.len - 1) and
         str[offset] == '\r' and str[offset + 1] == '\L':
        # if PCRE treats CrLf as newline, skip both at the same time
        offset += 2
      elif unicode:
        # XXX what about invalid unicode?
        offset += str.runeLenAt(offset)
        assert(offset <= strlen)
      else:
        offset += 1
    else:
      offset = match.get.matchBounds.b + 1

      yield match.get


proc find*(str: string, pattern: Regex, start = 0, endpos = int.high): Option[RegexMatch] =
  ## Finds the given pattern in the string between the end and start
  ## positions.
  ##
  ## ``start``
  ##     The start point at which to start matching. ``|abc`` is ``0``;
  ##     ``a|bc`` is ``1``
  ##
  ## ``endpos``
  ##     The maximum index for a match; ``int.high`` means the end of the
  ##     string, otherwise it’s an inclusive upper bound.
  return str.matchImpl(pattern, start, endpos, 0)

proc findAll*(str: string, pattern: Regex, start = 0, endpos = int.high): seq[string] =
  result = @[]
  for match in str.findIter(pattern, start, endpos):
    result.add(match.match)

proc split*(str: string, pattern: Regex, maxSplit = -1, start = 0): seq[string] =
  ## Splits the string with the given regex. This works according to the
  ## rules that Perl and Javascript use:
  ##
  ## -  If the match is zero-width, then the string is still split:
  ##    ``"123".split(r"") == @["1", "2", "3"]``.
  ##
  ## -  If the pattern has a capture in it, it is added after the string
  ##    split: ``"12".split(re"(\d)") == @["", "1", "", "2", ""]``.
  ##
  ## -  If ``maxsplit != -1``, then the string will only be split
  ##    ``maxsplit - 1`` times. This means that there will be ``maxsplit``
  ##    strings in the output seq.
  ##    ``"1.2.3".split(re"\.", maxsplit = 2) == @["1", "2.3"]``
  ##
  ## ``start`` behaves the same as in ```find(...)`` <#proc-find>`__.
  result = @[]
  var lastIdx = start
  var splits = 0
  var bounds = 0 .. -1
  var never_ran = true

  for match in str.findIter(pattern, start = start):
    never_ran = false

    # bounds are inclusive:
    #
    # 0123456
    #  ^^^
    # (1, 3)
    bounds = match.matchBounds

    # "12".split("") would be @["", "1", "2"], but
    # if we skip an empty first match, it's the correct
    # @["1", "2"]
    if bounds.a <= bounds.b or bounds.a > start:
      result.add(str.substr(lastIdx, bounds.a - 1))
      splits += 1

    lastIdx = bounds.b + 1

    for cap in match.captures:
      # if there are captures, include them in the result
      result.add(cap)

    if splits == maxSplit - 1:
      break

  # "12".split("\b") would be @["1", "2", ""], but
  # if we skip an empty last match, it's the correct
  # @["1", "2"]
  # If matches were never found, then the input string is the result
  if bounds.a <= bounds.b or bounds.b < str.high or never_ran:
    # last match: Each match takes the previous substring,
    # but "1 2".split(/ /) needs to return @["1", "2"].
    # This handles "2"
    result.add(str.substr(bounds.b + 1, str.high))

template replaceImpl(str: string, pattern: Regex,
                     replacement: expr): stmt {.immediate, dirty.} =
  # XXX seems very similar to split, maybe I can reduce code duplication
  # somehow?
  result = ""
  var lastIdx = 0
  for match {.inject.} in str.findIter(pattern):
    let bounds = match.matchBounds
    result.add(str.substr(lastIdx, bounds.a - 1))
    let nextVal = replacement
    assert(nextVal != nil)
    result.add(nextVal)

    lastIdx = bounds.b + 1

  result.add(str.substr(lastIdx, str.len - 1))
  return result

proc replace*(str: string, pattern: Regex,
              subproc: proc (match: RegexMatch): string): string =
  ## Replaces each match of Regex in the string with ``sub``, which should
  ## never be or return ``nil``.
  ##
  ## If ``sub`` is a ``proc (RegexMatch): string``, then it is executed with
  ## each match and the return value is the replacement value.
  ##
  ## If ``sub`` is a ``proc (string): string``, then it is executed with the
  ## full text of the match and and the return value is the replacement
  ## value.
  ##
  ## If ``sub`` is a string, the syntax is as follows:
  ##
  ## -  ``$$`` - literal ``$``
  ## -  ``$123`` - capture number ``123``
  ## -  ``$foo`` - named capture ``foo``
  ## -  ``${foo}`` - same as above
  ## -  ``$1$#`` - first and second captures
  ## -  ``$#`` - first capture
  ## -  ``$0`` - full match
  ##
  ## If a given capture is missing, a ``ValueError`` exception is thrown.
  replaceImpl(str, pattern, subproc(match))

proc replace*(str: string, pattern: Regex,
              subproc: proc (match: string): string): string =
  replaceImpl(str, pattern, subproc(match.match))

proc replace*(str: string, pattern: Regex, sub: string): string =
  # - 1 because the string numbers are 0-indexed
  replaceImpl(str, pattern,
    formatStr(sub, match.captures[name], match.captures[id - 1]))

# }}}

let SpecialCharMatcher = re"([\\+*?[^\]$(){}=!<>|:-])"
proc escapeRe*(str: string): string =
  ## Escapes the string so it doesn’t match any special characters.
  ## Incompatible with the Extra flag (``X``).
  str.replace(SpecialCharMatcher, "\\$1")

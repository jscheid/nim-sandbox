#
#
#            Nim's Runtime Library
#        (c) Copyright 2015 Andreas Rumpf
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.
#

## The compiler depends on the System module to work properly and the System
## module depends on the compiler. Most of the routines listed here use
## special compiler magic.
## Each module implicitly imports the System module; it must not be listed
## explicitly. Because of this there cannot be a user-defined module named
## ``system``.
##
## Module system
## =============
##

# That lonesome header above is to prevent :idx: entries from being mentioned
# in the global index as part of the previous header (Exception hierarchy).

type
  int* {.magic: Int.} ## default integer type; bitwidth depends on
                      ## architecture, but is always the same as a pointer
  int8* {.magic: Int8.} ## signed 8 bit integer type
  int16* {.magic: Int16.} ## signed 16 bit integer type
  int32* {.magic: Int32.} ## signed 32 bit integer type
  int64* {.magic: Int64.} ## signed 64 bit integer type
  uint* {.magic: UInt.} ## unsigned default integer type
  uint8* {.magic: UInt8.} ## unsigned 8 bit integer type
  uint16* {.magic: UInt16.} ## unsigned 16 bit integer type
  uint32* {.magic: UInt32.} ## unsigned 32 bit integer type
  uint64* {.magic: UInt64.} ## unsigned 64 bit integer type
  float* {.magic: Float.} ## default floating point type
  float32* {.magic: Float32.} ## 32 bit floating point type
  float64* {.magic: Float.} ## 64 bit floating point type

# 'float64' is now an alias to 'float'; this solves many problems

type # we need to start a new type section here, so that ``0`` can have a type
  bool* {.magic: Bool.} = enum ## built-in boolean type
    false = 0, true = 1

type
  char* {.magic: Char.} ## built-in 8 bit character type (unsigned)
  string* {.magic: String.} ## built-in string type
  cstring* {.magic: Cstring.} ## built-in cstring (*compatible string*) type
  pointer* {.magic: Pointer.} ## built-in pointer type, use the ``addr``
                              ## operator to get a pointer to a variable
const
  on* = true    ## alias for ``true``
  off* = false  ## alias for ``false``

{.push warning[GcMem]: off, warning[Uninit]: off.}
{.push hints: off.}

type
  Ordinal* {.magic: Ordinal.}[T] ## Generic ordinal type. Includes integer,
                                 ## bool, character, and enumeration types
                                 ## as well as their subtypes. Note `uint`
                                 ## and `uint64` are not ordinal types for
                                 ## implementation reasons
  `ptr`* {.magic: Pointer.}[T] ## built-in generic untraced pointer type
  `ref`* {.magic: Pointer.}[T] ## built-in generic traced pointer type

  `nil` {.magic: "Nil".}
  expr* {.magic: Expr.} ## meta type to denote an expression (for templates)
  stmt* {.magic: Stmt.} ## meta type to denote a statement (for templates)
  typedesc* {.magic: TypeDesc.} ## meta type to denote a type description
  void* {.magic: "VoidType".}   ## meta type to denote the absence of any type
  auto* {.magic: Expr.} ## meta type for automatic type determination
  any* = distinct auto ## meta type for any supported type
  untyped* {.magic: Expr.} ## meta type to denote an expression that
                           ## is not resolved (for templates)
  typed* {.magic: Stmt.}   ## meta type to denote an expression that
                           ## is resolved (for templates)

  SomeSignedInt* = int|int8|int16|int32|int64
    ## type class matching all signed integer types

  SomeUnsignedInt* = uint|uint8|uint16|uint32|uint64
    ## type class matching all unsigned integer types

  SomeInteger* = SomeSignedInt|SomeUnsignedInt
    ## type class matching all integer types

  SomeOrdinal* = int|int8|int16|int32|int64|bool|enum|uint8|uint16|uint32
    ## type class matching all ordinal types; however this includes enums with
    ## holes.

  SomeReal* = float|float32|float64
    ## type class matching all floating point number types

  SomeNumber* = SomeInteger|SomeReal
    ## type class matching all number types

proc defined*(x: expr): bool {.magic: "Defined", noSideEffect, compileTime.}
  ## Special compile-time procedure that checks whether `x` is
  ## defined.
  ## `x` is an external symbol introduced through the compiler's
  ## `-d:x switch <nimc.html#compile-time-symbols>`_ to enable build time
  ## conditionals:
  ##
  ## .. code-block:: Nim
  ##   when not defined(release):
  ##     # Do here programmer friendly expensive sanity checks.
  ##   # Put here the normal code

when defined(nimalias):
  {.deprecated: [
    TSignedInt: SomeSignedInt,
    TUnsignedInt: SomeUnsignedInt,
    TInteger: SomeInteger,
    TReal: SomeReal,
    TNumber: SomeNumber,
    TOrdinal: SomeOrdinal].}

proc declared*(x: expr): bool {.magic: "Defined", noSideEffect, compileTime.}
  ## Special compile-time procedure that checks whether `x` is
  ## declared. `x` has to be an identifier or a qualified identifier.
  ## This can be used to check whether a library provides a certain
  ## feature or not:
  ##
  ## .. code-block:: Nim
  ##   when not declared(strutils.toUpper):
  ##     # provide our own toUpper proc here, because strutils is
  ##     # missing it.

when defined(useNimRtl):
  {.deadCodeElim: on.}

proc definedInScope*(x: expr): bool {.
  magic: "DefinedInScope", noSideEffect, deprecated, compileTime.}
  ## **Deprecated since version 0.9.6**: Use ``declaredInScope`` instead.

proc declaredInScope*(x: expr): bool {.
  magic: "DefinedInScope", noSideEffect, compileTime.}
  ## Special compile-time procedure that checks whether `x` is
  ## declared in the current scope. `x` has to be an identifier.

proc `addr`*[T](x: var T): ptr T {.magic: "Addr", noSideEffect.} =
  ## Builtin 'addr' operator for taking the address of a memory location.
  ## Cannot be overloaded.
  ##
  ## .. code-block:: nim
  ##  var
  ##    buf: seq[char] = @['a','b','c']
  ##    p: pointer = buf[1].addr
  ##  echo cast[ptr char](p)[]    # b
  discard

proc unsafeAddr*[T](x: var T): ptr T {.magic: "Addr", noSideEffect.} =
  ## Builtin 'addr' operator for taking the address of a memory location.
  ## This works even for ``let`` variables or parameters for better interop
  ## with C and so it is considered even more unsafe than the ordinary ``addr``.
  ## Cannot be overloaded.
  discard

proc `type`*(x: expr): typeDesc {.magic: "TypeOf", noSideEffect, compileTime.} =
  ## Builtin 'type' operator for accessing the type of an expression.
  ## Cannot be overloaded.
  discard

proc `not` *(x: bool): bool {.magic: "Not", noSideEffect.}
  ## Boolean not; returns true iff ``x == false``.

proc `and`*(x, y: bool): bool {.magic: "And", noSideEffect.}
  ## Boolean ``and``; returns true iff ``x == y == true``.
  ## Evaluation is lazy: if ``x`` is false,
  ## ``y`` will not even be evaluated.
proc `or`*(x, y: bool): bool {.magic: "Or", noSideEffect.}
  ## Boolean ``or``; returns true iff ``not (not x and not y)``.
  ## Evaluation is lazy: if ``x`` is true,
  ## ``y`` will not even be evaluated.
proc `xor`*(x, y: bool): bool {.magic: "Xor", noSideEffect.}
  ## Boolean `exclusive or`; returns true iff ``x != y``.

proc new*[T](a: var ref T) {.magic: "New", noSideEffect.}
  ## creates a new object of type ``T`` and returns a safe (traced)
  ## reference to it in ``a``.

proc new*(T: typedesc): auto =
  ## creates a new object of type ``T`` and returns a safe (traced)
  ## reference to it as result value.
  ##
  ## When ``T`` is a ref type then the resulting type will be ``T``,
  ## otherwise it will be ``ref T``.
  when (T is ref):
    var r: T
  else:
    var r: ref T
  new(r)
  return r


proc internalNew*[T](a: var ref T) {.magic: "New", noSideEffect.}
  ## leaked implementation detail. Do not use.

proc new*[T](a: var ref T, finalizer: proc (x: ref T) {.nimcall.}) {.
  magic: "NewFinalize", noSideEffect.}
  ## creates a new object of type ``T`` and returns a safe (traced)
  ## reference to it in ``a``. When the garbage collector frees the object,
  ## `finalizer` is called. The `finalizer` may not keep a reference to the
  ## object pointed to by `x`. The `finalizer` cannot prevent the GC from
  ## freeing the object. Note: The `finalizer` refers to the type `T`, not to
  ## the object! This means that for each object of type `T` the finalizer
  ## will be called!

proc reset*[T](obj: var T) {.magic: "Reset", noSideEffect.}
  ## resets an object `obj` to its initial (binary zero) value. This needs to
  ## be called before any possible `object branch transition`:idx:.

# for low and high the return type T may not be correct, but
# we handle that with compiler magic in semLowHigh()
proc high*[T](x: T): T {.magic: "High", noSideEffect.}
  ## returns the highest possible index of an array, a sequence, a string or
  ## the highest possible value of an ordinal value `x`. As a special
  ## semantic rule, `x` may also be a type identifier.
  ## ``high(int)`` is Nim's way of writing `INT_MAX`:idx: or `MAX_INT`:idx:.
  ##
  ## .. code-block:: nim
  ##  var arr = [1,2,3,4,5,6,7]
  ##  high(arr) #=> 6
  ##  high(2) #=> 9223372036854775807

proc low*[T](x: T): T {.magic: "Low", noSideEffect.}
  ## returns the lowest possible index of an array, a sequence, a string or
  ## the lowest possible value of an ordinal value `x`. As a special
  ## semantic rule, `x` may also be a type identifier.
  ##
  ## .. code-block:: nim
  ##  var arr = [1,2,3,4,5,6,7]
  ##  high(arr) #=> 0
  ##  high(2) #=> -9223372036854775808

type
  range*{.magic: "Range".}[T] ## Generic type to construct range types.
  array*{.magic: "Array".}[I, T]  ## Generic type to construct
                                  ## fixed-length arrays.
  openArray*{.magic: "OpenArray".}[T]  ## Generic type to construct open arrays.
                                       ## Open arrays are implemented as a
                                       ## pointer to the array data and a
                                       ## length field.
  varargs*{.magic: "Varargs".}[T] ## Generic type to construct a varargs type.
  seq*{.magic: "Seq".}[T]  ## Generic type to construct sequences.
  set*{.magic: "Set".}[T]  ## Generic type to construct bit sets.

when defined(nimArrIdx):
  # :array|openarray|string|seq|cstring|tuple
  proc `[]`*[I: Ordinal;T](a: T; i: I): T {.
    noSideEffect, magic: "ArrGet".}
  proc `[]=`*[I: Ordinal;T,S](a: T; i: I;
    x: S) {.noSideEffect, magic: "ArrPut".}
  proc `=`*[T](dest: var T; src: T) {.noSideEffect, magic: "Asgn".}

type
  Slice*[T] = object ## builtin slice type
    a*, b*: T        ## the bounds

when defined(nimalias):
  {.deprecated: [TSlice: Slice].}

proc `..`*[T](a, b: T): Slice[T] {.noSideEffect, inline, magic: "DotDot".} =
  ## `slice`:idx: operator that constructs an interval ``[a, b]``, both `a`
  ## and `b` are inclusive. Slices can also be used in the set constructor
  ## and in ordinal case statements, but then they are special-cased by the
  ## compiler.
  result.a = a
  result.b = b

proc `..`*[T](b: T): Slice[T] {.noSideEffect, inline, magic: "DotDot".} =
  ## `slice`:idx: operator that constructs an interval ``[default(T), b]``
  result.b = b

when not defined(niminheritable):
  {.pragma: inheritable.}
when not defined(nimunion):
  {.pragma: unchecked.}

when defined(nimNewShared):
  type
    `shared`* {.magic: "Shared".}
    guarded* {.magic: "Guarded".}

# comparison operators:
proc `==` *[Enum: enum](x, y: Enum): bool {.magic: "EqEnum", noSideEffect.}
  ## Checks whether values within the *same enum* have the same underlying value
  ##
  ## .. code-block:: nim
  ##  type
  ##    Enum1 = enum
  ##      Field1 = 3, Field2
  ##    Enum2 = enum
  ##      Place1, Place2 = 3
  ##  var
  ##    e1 = Field1
  ##    e2 = Enum1(Place2)
  ##  echo (e1 == e2) # true
  ##  echo (e1 == Place2) # raises error
proc `==` *(x, y: pointer): bool {.magic: "EqRef", noSideEffect.}
  ## .. code-block:: nim
  ##  var # this is a wildly dangerous example
  ##    a = cast[pointer](0)
  ##    b = cast[pointer](nil)
  ##  echo (a == b) # true due to the special meaning of `nil`/0 as a pointer
proc `==` *(x, y: string): bool {.magic: "EqStr", noSideEffect.}
  ## Checks for equality between two `string` variables
proc `==` *(x, y: cstring): bool {.magic: "EqCString", noSideEffect.}
  ## Checks for equality between two `cstring` variables
proc `==` *(x, y: char): bool {.magic: "EqCh", noSideEffect.}
  ## Checks for equality between two `char` variables
proc `==` *(x, y: bool): bool {.magic: "EqB", noSideEffect.}
  ## Checks for equality between two `bool` variables
proc `==` *[T](x, y: set[T]): bool {.magic: "EqSet", noSideEffect.}
  ## Checks for equality between two variables of type `set`
  ##
  ## .. code-block:: nim
  ##  var a = {1, 2, 2, 3} # duplication in sets is ignored
  ##  var b = {1, 2, 3}
  ##  echo (a == b) # true
proc `==` *[T](x, y: ref T): bool {.magic: "EqRef", noSideEffect.}
  ## Checks that two `ref` variables refer to the same item
proc `==` *[T](x, y: ptr T): bool {.magic: "EqRef", noSideEffect.}
  ## Checks that two `ptr` variables refer to the same item
proc `==` *[T: proc](x, y: T): bool {.magic: "EqProc", noSideEffect.}
  ## Checks that two `proc` variables refer to the same procedure

proc `<=` *[Enum: enum](x, y: Enum): bool {.magic: "LeEnum", noSideEffect.}
proc `<=` *(x, y: string): bool {.magic: "LeStr", noSideEffect.}
proc `<=` *(x, y: char): bool {.magic: "LeCh", noSideEffect.}
proc `<=` *[T](x, y: set[T]): bool {.magic: "LeSet", noSideEffect.}
proc `<=` *(x, y: bool): bool {.magic: "LeB", noSideEffect.}
proc `<=` *[T](x, y: ref T): bool {.magic: "LePtr", noSideEffect.}
proc `<=` *(x, y: pointer): bool {.magic: "LePtr", noSideEffect.}

proc `<` *[Enum: enum](x, y: Enum): bool {.magic: "LtEnum", noSideEffect.}
proc `<` *(x, y: string): bool {.magic: "LtStr", noSideEffect.}
proc `<` *(x, y: char): bool {.magic: "LtCh", noSideEffect.}
proc `<` *[T](x, y: set[T]): bool {.magic: "LtSet", noSideEffect.}
proc `<` *(x, y: bool): bool {.magic: "LtB", noSideEffect.}
proc `<` *[T](x, y: ref T): bool {.magic: "LtPtr", noSideEffect.}
proc `<` *[T](x, y: ptr T): bool {.magic: "LtPtr", noSideEffect.}
proc `<` *(x, y: pointer): bool {.magic: "LtPtr", noSideEffect.}

template `!=` * (x, y: expr): expr {.immediate.} =
  ## unequals operator. This is a shorthand for ``not (x == y)``.
  not (x == y)

template `>=` * (x, y: expr): expr {.immediate.} =
  ## "is greater or equals" operator. This is the same as ``y <= x``.
  y <= x

template `>` * (x, y: expr): expr {.immediate.} =
  ## "is greater" operator. This is the same as ``y < x``.
  y < x

const
  appType* {.magic: "AppType"}: string = ""
    ## a string that describes the application type. Possible values:
    ## "console", "gui", "lib".

include "system/inclrtl"

const NoFakeVars* = defined(nimscript) ## true if the backend doesn't support \
  ## "fake variables" like 'var EBADF {.importc.}: cint'.

const ArrayDummySize = when defined(cpu16): 10_000 else: 100_000_000

when not defined(JS):
  type
    TGenericSeq {.compilerproc, pure, inheritable.} = object
      len, reserved: int
      when defined(gogc):
        elemSize: int
    PGenericSeq {.exportc.} = ptr TGenericSeq
    UncheckedCharArray {.unchecked.} = array[0..ArrayDummySize, char]
    # len and space without counting the terminating zero:
    NimStringDesc {.compilerproc, final.} = object of TGenericSeq
      data: UncheckedCharArray
    NimString = ptr NimStringDesc

when not defined(JS) and not defined(nimscript):
  template space(s: PGenericSeq): int {.dirty.} =
    s.reserved and not seqShallowFlag

  include "system/hti"

type
  byte* = uint8 ## this is an alias for ``uint8``, that is an unsigned
                ## int 8 bits wide.

  Natural* = range[0..high(int)]
    ## is an int type ranging from zero to the maximum value
    ## of an int. This type is often useful for documentation and debugging.

  Positive* = range[1..high(int)]
    ## is an int type ranging from one to the maximum value
    ## of an int. This type is often useful for documentation and debugging.

  RootObj* {.exportc: "TNimObject", inheritable.} =
    object ## the root of Nim's object hierarchy. Objects should
           ## inherit from RootObj or one of its descendants. However,
           ## objects that have no ancestor are allowed.
  RootRef* = ref RootObj ## reference to RootObj

  RootEffect* {.compilerproc.} = object of RootObj ## \
    ## base effect class; each effect should
    ## inherit from `TEffect` unless you know what
    ## you doing.
  TimeEffect* = object of RootEffect   ## Time effect.
  IOEffect* = object of RootEffect     ## IO effect.
  ReadIOEffect* = object of IOEffect   ## Effect describing a read IO operation.
  WriteIOEffect* = object of IOEffect  ## Effect describing a write IO operation.
  ExecIOEffect* = object of IOEffect   ## Effect describing an executing IO operation.

  Exception* {.compilerproc.} = object of RootObj ## \
    ## Base exception class.
    ##
    ## Each exception has to inherit from `Exception`. See the full `exception
    ## hierarchy`_.
    parent*: ref Exception ## parent exception (can be used as a stack)
    name*: cstring ## The exception's name is its Nim identifier.
                   ## This field is filled automatically in the
                   ## ``raise`` statement.
    msg* {.exportc: "message".}: string ## the exception's message. Not
                                        ## providing an exception message
                                        ## is bad style.
    trace: string

  SystemError* = object of Exception ## \
    ## Abstract class for exceptions that the runtime system raises.
    ##
    ## See the full `exception hierarchy`_.
  IOError* = object of SystemError ## \
    ## Raised if an IO error occurred.
    ##
    ## See the full `exception hierarchy`_.
  OSError* = object of SystemError ## \
    ## Raised if an operating system service failed.
    ##
    ## See the full `exception hierarchy`_.
    errorCode*: int32 ## OS-defined error code describing this error.
  LibraryError* = object of OSError ## \
    ## Raised if a dynamic library could not be loaded.
    ##
    ## See the full `exception hierarchy`_.
  ResourceExhaustedError* = object of SystemError ## \
    ## Raised if a resource request could not be fulfilled.
    ##
    ## See the full `exception hierarchy`_.
  ArithmeticError* = object of Exception ## \
    ## Raised if any kind of arithmetic error occurred.
    ##
    ## See the full `exception hierarchy`_.
  DivByZeroError* = object of ArithmeticError ## \
    ## Raised for runtime integer divide-by-zero errors.
    ##
    ## See the full `exception hierarchy`_.

  OverflowError* = object of ArithmeticError ## \
    ## Raised for runtime integer overflows.
    ##
    ## This happens for calculations whose results are too large to fit in the
    ## provided bits.  See the full `exception hierarchy`_.
  AccessViolationError* = object of Exception ## \
    ## Raised for invalid memory access errors
    ##
    ## See the full `exception hierarchy`_.
  AssertionError* = object of Exception ## \
    ## Raised when assertion is proved wrong.
    ##
    ## Usually the result of using the `assert() template <#assert>`_.  See the
    ## full `exception hierarchy`_.
  ValueError* = object of Exception ## \
    ## Raised for string and object conversion errors.
  KeyError* = object of ValueError ## \
    ## Raised if a key cannot be found in a table.
    ##
    ## Mostly used by the `tables <tables.html>`_ module, it can also be raised
    ## by other collection modules like `sets <sets.html>`_ or `strtabs
    ## <strtabs.html>`_. See the full `exception hierarchy`_.
  OutOfMemError* = object of SystemError ## \
    ## Raised for unsuccessful attempts to allocate memory.
    ##
    ## See the full `exception hierarchy`_.
  IndexError* = object of Exception ## \
    ## Raised if an array index is out of bounds.
    ##
    ## See the full `exception hierarchy`_.

  FieldError* = object of Exception ## \
    ## Raised if a record field is not accessible because its dicriminant's
    ## value does not fit.
    ##
    ## See the full `exception hierarchy`_.
  RangeError* = object of Exception ## \
    ## Raised if a range check error occurred.
    ##
    ## See the full `exception hierarchy`_.
  StackOverflowError* = object of SystemError ## \
    ## Raised if the hardware stack used for subroutine calls overflowed.
    ##
    ## See the full `exception hierarchy`_.
  ReraiseError* = object of Exception ## \
    ## Raised if there is no exception to reraise.
    ##
    ## See the full `exception hierarchy`_.
  ObjectAssignmentError* = object of Exception ## \
    ## Raised if an object gets assigned to its parent's object.
    ##
    ## See the full `exception hierarchy`_.
  ObjectConversionError* = object of Exception ## \
    ## Raised if an object is converted to an incompatible object type.
    ## You can use ``of`` operator to check if conversion will succeed.
    ##
    ## See the full `exception hierarchy`_.
  FloatingPointError* = object of Exception ## \
    ## Base class for floating point exceptions.
    ##
    ## See the full `exception hierarchy`_.
  FloatInvalidOpError* = object of FloatingPointError ## \
    ## Raised by invalid operations according to IEEE.
    ##
    ## Raised by ``0.0/0.0``, for example.  See the full `exception
    ## hierarchy`_.
  FloatDivByZeroError* = object of FloatingPointError ## \
    ## Raised by division by zero.
    ##
    ## Divisor is zero and dividend is a finite nonzero number.  See the full
    ## `exception hierarchy`_.
  FloatOverflowError* = object of FloatingPointError ## \
    ## Raised for overflows.
    ##
    ## The operation produced a result that exceeds the range of the exponent.
    ## See the full `exception hierarchy`_.
  FloatUnderflowError* = object of FloatingPointError ## \
    ## Raised for underflows.
    ##
    ## The operation produced a result that is too small to be represented as a
    ## normal number. See the full `exception hierarchy`_.
  FloatInexactError* = object of FloatingPointError ## \
    ## Raised for inexact results.
    ##
    ## The operation produced a result that cannot be represented with infinite
    ## precision -- for example: ``2.0 / 3.0, log(1.1)``
    ##
    ## **NOTE**: Nim currently does not detect these!  See the full
    ## `exception hierarchy`_.
  DeadThreadError* = object of Exception ## \
    ## Raised if it is attempted to send a message to a dead thread.
    ##
    ## See the full `exception hierarchy`_.

  TResult* {.deprecated.} = enum Failure, Success

{.deprecated: [TObject: RootObj, PObject: RootRef, TEffect: RootEffect,
  FTime: TimeEffect, FIO: IOEffect, FReadIO: ReadIOEffect,
  FWriteIO: WriteIOEffect, FExecIO: ExecIOEffect,

  E_Base: Exception, ESystem: SystemError, EIO: IOError,
  EOS: OSError, EInvalidLibrary: LibraryError,
  EResourceExhausted: ResourceExhaustedError,
  EArithmetic: ArithmeticError, EDivByZero: DivByZeroError,
  EOverflow: OverflowError, EAccessViolation: AccessViolationError,
  EAssertionFailed: AssertionError, EInvalidValue: ValueError,
  EInvalidKey: KeyError, EOutOfMemory: OutOfMemError,
  EInvalidIndex: IndexError, EInvalidField: FieldError,
  EOutOfRange: RangeError, EStackOverflow: StackOverflowError,
  ENoExceptionToReraise: ReraiseError,
  EInvalidObjectAssignment: ObjectAssignmentError,
  EInvalidObjectConversion: ObjectConversionError,
  EDeadThread: DeadThreadError,
  EFloatInexact: FloatInexactError,
  EFloatUnderflow: FloatUnderflowError,
  EFloatingPoint: FloatingPointError,
  EFloatInvalidOp: FloatInvalidOpError,
  EFloatDivByZero: FloatDivByZeroError,
  EFloatOverflow: FloatOverflowError,
  ESynch: Exception
].}

proc unsafeNew*[T](a: var ref T, size: Natural) {.magic: "New", noSideEffect.}
  ## creates a new object of type ``T`` and returns a safe (traced)
  ## reference to it in ``a``. This is **unsafe** as it allocates an object
  ## of the passed ``size``. This should only be used for optimization
  ## purposes when you know what you're doing!

proc sizeof*[T](x: T): int {.magic: "SizeOf", noSideEffect.}
  ## returns the size of ``x`` in bytes. Since this is a low-level proc,
  ## its usage is discouraged - using ``new`` for the most cases suffices
  ## that one never needs to know ``x``'s size. As a special semantic rule,
  ## ``x`` may also be a type identifier (``sizeof(int)`` is valid).
  ##
  ## .. code-block:: nim
  ##  sizeof('A') #=> 1
  ##  sizeof(2) #=> 8

when defined(nimtypedescfixed):
  proc sizeof*(x: typedesc): int {.magic: "SizeOf", noSideEffect.}

proc `<`*[T](x: Ordinal[T]): T {.magic: "UnaryLt", noSideEffect.}
  ## unary ``<`` that can be used for nice looking excluding ranges:
  ##
  ## .. code-block:: nim
  ##   for i in 0 .. <10: echo i
  ##
  ## Semantically this is the same as ``pred``.

proc succ*[T](x: Ordinal[T], y = 1): T {.magic: "Succ", noSideEffect.}
  ## returns the ``y``-th successor of the value ``x``. ``T`` has to be
  ## an ordinal type. If such a value does not exist, ``EOutOfRange`` is raised
  ## or a compile time error occurs.

proc pred*[T](x: Ordinal[T], y = 1): T {.magic: "Pred", noSideEffect.}
  ## returns the ``y``-th predecessor of the value ``x``. ``T`` has to be
  ## an ordinal type. If such a value does not exist, ``EOutOfRange`` is raised
  ## or a compile time error occurs.

proc inc*[T: Ordinal|uint|uint64](x: var T, y = 1) {.magic: "Inc", noSideEffect.}
  ## increments the ordinal ``x`` by ``y``. If such a value does not
  ## exist, ``EOutOfRange`` is raised or a compile time error occurs. This is a
  ## short notation for: ``x = succ(x, y)``.
  ##
  ## .. code-block:: nim
  ##  var i = 2
  ##  inc(i) #=> 3
  ##  inc(i, 3) #=> 6

proc dec*[T: Ordinal|uint|uint64](x: var T, y = 1) {.magic: "Dec", noSideEffect.}
  ## decrements the ordinal ``x`` by ``y``. If such a value does not
  ## exist, ``EOutOfRange`` is raised or a compile time error occurs. This is a
  ## short notation for: ``x = pred(x, y)``.
  ##
  ## .. code-block:: nim
  ##  var i = 2
  ##  dec(i) #=> 1
  ##  dec(i, 3) #=> -2

proc newSeq*[T](s: var seq[T], len: Natural) {.magic: "NewSeq", noSideEffect.}
  ## creates a new sequence of type ``seq[T]`` with length ``len``.
  ## This is equivalent to ``s = @[]; setlen(s, len)``, but more
  ## efficient since no reallocation is needed.
  ##
  ## Note that the sequence will be filled with zeroed entries, which can be a
  ## problem for sequences containing strings since their value will be
  ## ``nil``. After the creation of the sequence you should assign entries to
  ## the sequence instead of adding them. Example:
  ##
  ## .. code-block:: nim
  ##   var inputStrings : seq[string]
  ##   newSeq(inputStrings, 3)
  ##   inputStrings[0] = "The fourth"
  ##   inputStrings[1] = "assignment"
  ##   inputStrings[2] = "would crash"
  ##   #inputStrings[3] = "out of bounds"

proc newSeq*[T](len = 0.Natural): seq[T] =
  ## creates a new sequence of type ``seq[T]`` with length ``len``.
  ##
  ## Note that the sequence will be filled with zeroed entries, which can be a
  ## problem for sequences containing strings since their value will be
  ## ``nil``. After the creation of the sequence you should assign entries to
  ## the sequence instead of adding them. Example:
  ##
  ## .. code-block:: nim
  ##   var inputStrings = newSeq[string](3)
  ##   inputStrings[0] = "The fourth"
  ##   inputStrings[1] = "assignment"
  ##   inputStrings[2] = "would crash"
  ##   #inputStrings[3] = "out of bounds"
  newSeq(result, len)

proc len*[TOpenArray: openArray|varargs](x: TOpenArray): int {.
  magic: "LengthOpenArray", noSideEffect.}
proc len*(x: string): int {.magic: "LengthStr", noSideEffect.}
proc len*(x: cstring): int {.magic: "LengthStr", noSideEffect.}
proc len*[I, T](x: array[I, T]): int {.magic: "LengthArray", noSideEffect.}
proc len*[T](x: seq[T]): int {.magic: "LengthSeq", noSideEffect.}
  ## returns the length of an array, an openarray, a sequence or a string.
  ## This is roughly the same as ``high(T)-low(T)+1``, but its resulting type is
  ## always an int.
  ##
  ## .. code-block:: nim
  ##  var arr = [1,1,1,1,1]
  ##  len(arr) #=> 5
  ##  for i in 0..<arr.len:
  ##    echo arr[i] #=> 1,1,1,1,1

# set routines:
proc incl*[T](x: var set[T], y: T) {.magic: "Incl", noSideEffect.}
  ## includes element ``y`` to the set ``x``. This is the same as
  ## ``x = x + {y}``, but it might be more efficient.
  ##
  ## .. code-block:: nim
  ##  var a = initSet[int](4)
  ##  a.incl(2) #=> {2}
  ##  a.incl(3) #=> {2, 3}

template incl*[T](s: var set[T], flags: set[T]) =
  ## includes the set of flags to the set ``x``.
  s = s + flags

proc excl*[T](x: var set[T], y: T) {.magic: "Excl", noSideEffect.}
  ## excludes element ``y`` to the set ``x``. This is the same as
  ## ``x = x - {y}``, but it might be more efficient.
  ##
  ## .. code-block:: nim
  ##  var b = {2,3,5,6,12,545}
  ##  b.excl(5)  #=> {2,3,6,12,545}

template excl*[T](s: var set[T], flags: set[T]) =
  ## excludes the set of flags to ``x``.
  s = s - flags

proc card*[T](x: set[T]): int {.magic: "Card", noSideEffect.}
  ## returns the cardinality of the set ``x``, i.e. the number of elements
  ## in the set.
  ##
  ## .. code-block:: nim
  ##  var i = {1,2,3,4}
  ##  card(i) #=> 4

proc ord*[T](x: T): int {.magic: "Ord", noSideEffect.}
  ## returns the internal int value of an ordinal value ``x``.
  ##
  ## .. code-block:: nim
  ##  ord('A') #=> 65

proc chr*(u: range[0..255]): char {.magic: "Chr", noSideEffect.}
  ## converts an int in the range 0..255 to a character.
  ##
  ## .. code-block:: nim
  ##  chr(65) #=> A

# --------------------------------------------------------------------------
# built-in operators

when not defined(JS):
  proc ze*(x: int8): int {.magic: "Ze8ToI", noSideEffect.}
    ## zero extends a smaller integer type to ``int``. This treats `x` as
    ## unsigned.
  proc ze*(x: int16): int {.magic: "Ze16ToI", noSideEffect.}
    ## zero extends a smaller integer type to ``int``. This treats `x` as
    ## unsigned.

  proc ze64*(x: int8): int64 {.magic: "Ze8ToI64", noSideEffect.}
    ## zero extends a smaller integer type to ``int64``. This treats `x` as
    ## unsigned.
  proc ze64*(x: int16): int64 {.magic: "Ze16ToI64", noSideEffect.}
    ## zero extends a smaller integer type to ``int64``. This treats `x` as
    ## unsigned.

  proc ze64*(x: int32): int64 {.magic: "Ze32ToI64", noSideEffect.}
    ## zero extends a smaller integer type to ``int64``. This treats `x` as
    ## unsigned.
  proc ze64*(x: int): int64 {.magic: "ZeIToI64", noSideEffect.}
    ## zero extends a smaller integer type to ``int64``. This treats `x` as
    ## unsigned. Does nothing if the size of an ``int`` is the same as ``int64``.
    ## (This is the case on 64 bit processors.)

  proc toU8*(x: int): int8 {.magic: "ToU8", noSideEffect.}
    ## treats `x` as unsigned and converts it to a byte by taking the last 8 bits
    ## from `x`.
  proc toU16*(x: int): int16 {.magic: "ToU16", noSideEffect.}
    ## treats `x` as unsigned and converts it to an ``int16`` by taking the last
    ## 16 bits from `x`.
  proc toU32*(x: int64): int32 {.magic: "ToU32", noSideEffect.}
    ## treats `x` as unsigned and converts it to an ``int32`` by taking the
    ## last 32 bits from `x`.

# integer calculations:
proc `+` *(x: int): int {.magic: "UnaryPlusI", noSideEffect.}
proc `+` *(x: int8): int8 {.magic: "UnaryPlusI", noSideEffect.}
proc `+` *(x: int16): int16 {.magic: "UnaryPlusI", noSideEffect.}
proc `+` *(x: int32): int32 {.magic: "UnaryPlusI", noSideEffect.}
proc `+` *(x: int64): int64 {.magic: "UnaryPlusI", noSideEffect.}
  ## Unary `+` operator for an integer. Has no effect.

proc `-` *(x: int): int {.magic: "UnaryMinusI", noSideEffect.}
proc `-` *(x: int8): int8 {.magic: "UnaryMinusI", noSideEffect.}
proc `-` *(x: int16): int16 {.magic: "UnaryMinusI", noSideEffect.}
proc `-` *(x: int32): int32 {.magic: "UnaryMinusI", noSideEffect.}
proc `-` *(x: int64): int64 {.magic: "UnaryMinusI64", noSideEffect.}
  ## Unary `-` operator for an integer. Negates `x`.

proc `not` *(x: int): int {.magic: "BitnotI", noSideEffect.}
proc `not` *(x: int8): int8 {.magic: "BitnotI", noSideEffect.}
proc `not` *(x: int16): int16 {.magic: "BitnotI", noSideEffect.}
proc `not` *(x: int32): int32 {.magic: "BitnotI", noSideEffect.}
  ## computes the `bitwise complement` of the integer `x`.

when defined(nimnomagic64):
  proc `not` *(x: int64): int64 {.magic: "BitnotI", noSideEffect.}
else:
  proc `not` *(x: int64): int64 {.magic: "BitnotI64", noSideEffect.}

proc `+` *(x, y: int): int {.magic: "AddI", noSideEffect.}
proc `+` *(x, y: int8): int8 {.magic: "AddI", noSideEffect.}
proc `+` *(x, y: int16): int16 {.magic: "AddI", noSideEffect.}
proc `+` *(x, y: int32): int32 {.magic: "AddI", noSideEffect.}
  ## Binary `+` operator for an integer.

when defined(nimnomagic64):
  proc `+` *(x, y: int64): int64 {.magic: "AddI", noSideEffect.}
else:
  proc `+` *(x, y: int64): int64 {.magic: "AddI64", noSideEffect.}

proc `-` *(x, y: int): int {.magic: "SubI", noSideEffect.}
proc `-` *(x, y: int8): int8 {.magic: "SubI", noSideEffect.}
proc `-` *(x, y: int16): int16 {.magic: "SubI", noSideEffect.}
proc `-` *(x, y: int32): int32 {.magic: "SubI", noSideEffect.}
  ## Binary `-` operator for an integer.

when defined(nimnomagic64):
  proc `-` *(x, y: int64): int64 {.magic: "SubI", noSideEffect.}
else:
  proc `-` *(x, y: int64): int64 {.magic: "SubI64", noSideEffect.}

proc `*` *(x, y: int): int {.magic: "MulI", noSideEffect.}
proc `*` *(x, y: int8): int8 {.magic: "MulI", noSideEffect.}
proc `*` *(x, y: int16): int16 {.magic: "MulI", noSideEffect.}
proc `*` *(x, y: int32): int32 {.magic: "MulI", noSideEffect.}
  ## Binary `*` operator for an integer.

when defined(nimnomagic64):
  proc `*` *(x, y: int64): int64 {.magic: "MulI", noSideEffect.}
else:
  proc `*` *(x, y: int64): int64 {.magic: "MulI64", noSideEffect.}

proc `div` *(x, y: int): int {.magic: "DivI", noSideEffect.}
proc `div` *(x, y: int8): int8 {.magic: "DivI", noSideEffect.}
proc `div` *(x, y: int16): int16 {.magic: "DivI", noSideEffect.}
proc `div` *(x, y: int32): int32 {.magic: "DivI", noSideEffect.}
  ## computes the integer division. This is roughly the same as
  ## ``floor(x/y)``.
  ##
  ## .. code-block:: Nim
  ##   1 div 2 == 0
  ##   2 div 2 == 1
  ##   3 div 2 == 1
  ##   7 div 5 == 2

when defined(nimnomagic64):
  proc `div` *(x, y: int64): int64 {.magic: "DivI", noSideEffect.}
else:
  proc `div` *(x, y: int64): int64 {.magic: "DivI64", noSideEffect.}

proc `mod` *(x, y: int): int {.magic: "ModI", noSideEffect.}
proc `mod` *(x, y: int8): int8 {.magic: "ModI", noSideEffect.}
proc `mod` *(x, y: int16): int16 {.magic: "ModI", noSideEffect.}
proc `mod` *(x, y: int32): int32 {.magic: "ModI", noSideEffect.}
  ## computes the integer modulo operation (remainder).
  ## This is the same as
  ## ``x - (x div y) * y``.
  ##
  ## .. code-block:: Nim
  ##   (7 mod 5) == 2

when defined(nimnomagic64):
  proc `mod` *(x, y: int64): int64 {.magic: "ModI", noSideEffect.}
else:
  proc `mod` *(x, y: int64): int64 {.magic: "ModI64", noSideEffect.}

proc `shr` *(x, y: int): int {.magic: "ShrI", noSideEffect.}
proc `shr` *(x, y: int8): int8 {.magic: "ShrI", noSideEffect.}
proc `shr` *(x, y: int16): int16 {.magic: "ShrI", noSideEffect.}
proc `shr` *(x, y: int32): int32 {.magic: "ShrI", noSideEffect.}
proc `shr` *(x, y: int64): int64 {.magic: "ShrI", noSideEffect.}
  ## computes the `shift right` operation of `x` and `y`, filling
  ## vacant bit positions with zeros.
  ##
  ## .. code-block:: Nim
  ##   0b0001_0000'i8 shr 2 == 0b0000_0100'i8
  ##   0b1000_0000'i8 shr 8 == 0b0000_0000'i8
  ##   0b0000_0001'i8 shr 1 == 0b0000_0000'i8

proc `shl` *(x, y: int): int {.magic: "ShlI", noSideEffect.}
proc `shl` *(x, y: int8): int8 {.magic: "ShlI", noSideEffect.}
proc `shl` *(x, y: int16): int16 {.magic: "ShlI", noSideEffect.}
proc `shl` *(x, y: int32): int32 {.magic: "ShlI", noSideEffect.}
proc `shl` *(x, y: int64): int64 {.magic: "ShlI", noSideEffect.}
  ## computes the `shift left` operation of `x` and `y`.
  ##
  ## .. code-block:: Nim
  ##  1'i32 shl 4  == 0x0000_0010
  ##  1'i64 shl 4  == 0x0000_0000_0000_0010

proc `and` *(x, y: int): int {.magic: "BitandI", noSideEffect.}
proc `and` *(x, y: int8): int8 {.magic: "BitandI", noSideEffect.}
proc `and` *(x, y: int16): int16 {.magic: "BitandI", noSideEffect.}
proc `and` *(x, y: int32): int32 {.magic: "BitandI", noSideEffect.}
proc `and` *(x, y: int64): int64 {.magic: "BitandI", noSideEffect.}
  ## computes the `bitwise and` of numbers `x` and `y`.
  ##
  ## .. code-block:: Nim
  ##  (0xffff'i16 and 0x0010'i16) == 0x0010

proc `or` *(x, y: int): int {.magic: "BitorI", noSideEffect.}
proc `or` *(x, y: int8): int8 {.magic: "BitorI", noSideEffect.}
proc `or` *(x, y: int16): int16 {.magic: "BitorI", noSideEffect.}
proc `or` *(x, y: int32): int32 {.magic: "BitorI", noSideEffect.}
proc `or` *(x, y: int64): int64 {.magic: "BitorI", noSideEffect.}
  ## computes the `bitwise or` of numbers `x` and `y`.
  ##
  ## .. code-block:: Nim
  ##  (0x0005'i16 or 0x0010'i16) == 0x0015

proc `xor` *(x, y: int): int {.magic: "BitxorI", noSideEffect.}
proc `xor` *(x, y: int8): int8 {.magic: "BitxorI", noSideEffect.}
proc `xor` *(x, y: int16): int16 {.magic: "BitxorI", noSideEffect.}
proc `xor` *(x, y: int32): int32 {.magic: "BitxorI", noSideEffect.}
proc `xor` *(x, y: int64): int64 {.magic: "BitxorI", noSideEffect.}
  ## computes the `bitwise xor` of numbers `x` and `y`.
  ##
  ## .. code-block:: Nim
  ##  (0x1011'i16 xor 0x0101'i16) == 0x1110

proc `==` *(x, y: int): bool {.magic: "EqI", noSideEffect.}
proc `==` *(x, y: int8): bool {.magic: "EqI", noSideEffect.}
proc `==` *(x, y: int16): bool {.magic: "EqI", noSideEffect.}
proc `==` *(x, y: int32): bool {.magic: "EqI", noSideEffect.}
proc `==` *(x, y: int64): bool {.magic: "EqI", noSideEffect.}
  ## Compares two integers for equality.

proc `<=` *(x, y: int): bool {.magic: "LeI", noSideEffect.}
proc `<=` *(x, y: int8): bool {.magic: "LeI", noSideEffect.}
proc `<=` *(x, y: int16): bool {.magic: "LeI", noSideEffect.}
proc `<=` *(x, y: int32): bool {.magic: "LeI", noSideEffect.}
proc `<=` *(x, y: int64): bool {.magic: "LeI", noSideEffect.}
  ## Returns true iff `x` is less than or equal to `y`.

proc `<` *(x, y: int): bool {.magic: "LtI", noSideEffect.}
proc `<` *(x, y: int8): bool {.magic: "LtI", noSideEffect.}
proc `<` *(x, y: int16): bool {.magic: "LtI", noSideEffect.}
proc `<` *(x, y: int32): bool {.magic: "LtI", noSideEffect.}
proc `<` *(x, y: int64): bool {.magic: "LtI", noSideEffect.}
  ## Returns true iff `x` is less than `y`.

type
  IntMax32 = int|int8|int16|int32

proc `+%` *(x, y: IntMax32): IntMax32 {.magic: "AddU", noSideEffect.}
proc `+%` *(x, y: int64): int64 {.magic: "AddU", noSideEffect.}
  ## treats `x` and `y` as unsigned and adds them. The result is truncated to
  ## fit into the result. This implements modulo arithmetic. No overflow
  ## errors are possible.

proc `-%` *(x, y: IntMax32): IntMax32 {.magic: "SubU", noSideEffect.}
proc `-%` *(x, y: int64): int64 {.magic: "SubU", noSideEffect.}
  ## treats `x` and `y` as unsigned and subtracts them. The result is
  ## truncated to fit into the result. This implements modulo arithmetic.
  ## No overflow errors are possible.

proc `*%` *(x, y: IntMax32): IntMax32 {.magic: "MulU", noSideEffect.}
proc `*%` *(x, y: int64): int64 {.magic: "MulU", noSideEffect.}
  ## treats `x` and `y` as unsigned and multiplies them. The result is
  ## truncated to fit into the result. This implements modulo arithmetic.
  ## No overflow errors are possible.

proc `/%` *(x, y: IntMax32): IntMax32 {.magic: "DivU", noSideEffect.}
proc `/%` *(x, y: int64): int64 {.magic: "DivU", noSideEffect.}
  ## treats `x` and `y` as unsigned and divides them. The result is
  ## truncated to fit into the result. This implements modulo arithmetic.
  ## No overflow errors are possible.

proc `%%` *(x, y: IntMax32): IntMax32 {.magic: "ModU", noSideEffect.}
proc `%%` *(x, y: int64): int64 {.magic: "ModU", noSideEffect.}
  ## treats `x` and `y` as unsigned and compute the modulo of `x` and `y`.
  ## The result is truncated to fit into the result.
  ## This implements modulo arithmetic.
  ## No overflow errors are possible.

proc `<=%` *(x, y: IntMax32): bool {.magic: "LeU", noSideEffect.}
proc `<=%` *(x, y: int64): bool {.magic: "LeU64", noSideEffect.}
  ## treats `x` and `y` as unsigned and compares them.
  ## Returns true iff ``unsigned(x) <= unsigned(y)``.

proc `<%` *(x, y: IntMax32): bool {.magic: "LtU", noSideEffect.}
proc `<%` *(x, y: int64): bool {.magic: "LtU64", noSideEffect.}
  ## treats `x` and `y` as unsigned and compares them.
  ## Returns true iff ``unsigned(x) < unsigned(y)``.

# unsigned integer operations:
proc `not`*[T: SomeUnsignedInt](x: T): T {.magic: "BitnotI", noSideEffect.}
  ## computes the `bitwise complement` of the integer `x`.

proc `shr`*[T: SomeUnsignedInt](x, y: T): T {.magic: "ShrI", noSideEffect.}
  ## computes the `shift right` operation of `x` and `y`.

proc `shl`*[T: SomeUnsignedInt](x, y: T): T {.magic: "ShlI", noSideEffect.}
  ## computes the `shift left` operation of `x` and `y`.

proc `and`*[T: SomeUnsignedInt](x, y: T): T {.magic: "BitandI", noSideEffect.}
  ## computes the `bitwise and` of numbers `x` and `y`.

proc `or`*[T: SomeUnsignedInt](x, y: T): T {.magic: "BitorI", noSideEffect.}
  ## computes the `bitwise or` of numbers `x` and `y`.

proc `xor`*[T: SomeUnsignedInt](x, y: T): T {.magic: "BitxorI", noSideEffect.}
  ## computes the `bitwise xor` of numbers `x` and `y`.

proc `==`*[T: SomeUnsignedInt](x, y: T): bool {.magic: "EqI", noSideEffect.}
  ## Compares two unsigned integers for equality.

proc `+`*[T: SomeUnsignedInt](x, y: T): T {.magic: "AddU", noSideEffect.}
  ## Binary `+` operator for unsigned integers.

proc `-`*[T: SomeUnsignedInt](x, y: T): T {.magic: "SubU", noSideEffect.}
  ## Binary `-` operator for unsigned integers.

proc `*`*[T: SomeUnsignedInt](x, y: T): T {.magic: "MulU", noSideEffect.}
  ## Binary `*` operator for unsigned integers.

proc `div`*[T: SomeUnsignedInt](x, y: T): T {.magic: "DivU", noSideEffect.}
  ## computes the integer division. This is roughly the same as
  ## ``floor(x/y)``.
  ##
  ## .. code-block:: Nim
  ##  (7 div 5) == 2

proc `mod`*[T: SomeUnsignedInt](x, y: T): T {.magic: "ModU", noSideEffect.}
  ## computes the integer modulo operation (remainder).
  ## This is the same as
  ## ``x - (x div y) * y``.
  ##
  ## .. code-block:: Nim
  ##   (7 mod 5) == 2

proc `<=`*[T: SomeUnsignedInt](x, y: T): bool {.magic: "LeU", noSideEffect.}
  ## Returns true iff ``x <= y``.

proc `<`*[T: SomeUnsignedInt](x, y: T): bool {.magic: "LtU", noSideEffect.}
  ## Returns true iff ``unsigned(x) < unsigned(y)``.

# floating point operations:
proc `+` *(x: float32): float32 {.magic: "UnaryPlusF64", noSideEffect.}
proc `-` *(x: float32): float32 {.magic: "UnaryMinusF64", noSideEffect.}
proc `+` *(x, y: float32): float32 {.magic: "AddF64", noSideEffect.}
proc `-` *(x, y: float32): float32 {.magic: "SubF64", noSideEffect.}
proc `*` *(x, y: float32): float32 {.magic: "MulF64", noSideEffect.}
proc `/` *(x, y: float32): float32 {.magic: "DivF64", noSideEffect.}

proc `+` *(x: float): float {.magic: "UnaryPlusF64", noSideEffect.}
proc `-` *(x: float): float {.magic: "UnaryMinusF64", noSideEffect.}
proc `+` *(x, y: float): float {.magic: "AddF64", noSideEffect.}
proc `-` *(x, y: float): float {.magic: "SubF64", noSideEffect.}
proc `*` *(x, y: float): float {.magic: "MulF64", noSideEffect.}
proc `/` *(x, y: float): float {.magic: "DivF64", noSideEffect.}
  ## computes the floating point division

proc `==` *(x, y: float32): bool {.magic: "EqF64", noSideEffect.}
proc `<=` *(x, y: float32): bool {.magic: "LeF64", noSideEffect.}
proc `<`  *(x, y: float32): bool {.magic: "LtF64", noSideEffect.}

proc `==` *(x, y: float): bool {.magic: "EqF64", noSideEffect.}
proc `<=` *(x, y: float): bool {.magic: "LeF64", noSideEffect.}
proc `<`  *(x, y: float): bool {.magic: "LtF64", noSideEffect.}

# set operators
proc `*` *[T](x, y: set[T]): set[T] {.magic: "MulSet", noSideEffect.}
  ## This operator computes the intersection of two sets.
proc `+` *[T](x, y: set[T]): set[T] {.magic: "PlusSet", noSideEffect.}
  ## This operator computes the union of two sets.
proc `-` *[T](x, y: set[T]): set[T] {.magic: "MinusSet", noSideEffect.}
  ## This operator computes the difference of two sets.

proc contains*[T](x: set[T], y: T): bool {.magic: "InSet", noSideEffect.}
  ## One should overload this proc if one wants to overload the ``in`` operator.
  ## The parameters are in reverse order! ``a in b`` is a template for
  ## ``contains(b, a)``.
  ## This is because the unification algorithm that Nim uses for overload
  ## resolution works from left to right.
  ## But for the ``in`` operator that would be the wrong direction for this
  ## piece of code:
  ##
  ## .. code-block:: Nim
  ##   var s: set[range['a'..'z']] = {'a'..'c'}
  ##   writeLine(stdout, 'b' in s)
  ##
  ## If ``in`` had been declared as ``[T](elem: T, s: set[T])`` then ``T`` would
  ## have been bound to ``char``. But ``s`` is not compatible to type
  ## ``set[char]``! The solution is to bind ``T`` to ``range['a'..'z']``. This
  ## is achieved by reversing the parameters for ``contains``; ``in`` then
  ## passes its arguments in reverse order.

proc contains*[T](s: Slice[T], value: T): bool {.noSideEffect, inline.} =
  ## Checks if `value` is within the range of `s`; returns true iff
  ## `value >= s.a and value <= s.b`
  ##
  ## .. code-block:: Nim
  ##   assert((1..3).contains(1) == true)
  ##   assert((1..3).contains(2) == true)
  ##   assert((1..3).contains(4) == false)
  result = s.a <= value and value <= s.b

template `in` * (x, y: expr): expr {.immediate, dirty.} = contains(y, x)
  ## Sugar for contains
  ##
  ## .. code-block:: Nim
  ##   assert(1 in (1..3) == true)
  ##   assert(5 in (1..3) == false)
template `notin` * (x, y: expr): expr {.immediate, dirty.} = not contains(y, x)
  ## Sugar for not containing
  ##
  ## .. code-block:: Nim
  ##   assert(1 notin (1..3) == false)
  ##   assert(5 notin (1..3) == true)

proc `is` *[T, S](x: T, y: S): bool {.magic: "Is", noSideEffect.}
  ## Checks if T is of the same type as S
  ##
  ## .. code-block:: Nim
  ##   proc test[T](a: T): int =
  ##     when (T is int):
  ##       return a
  ##     else:
  ##       return 0
  ##
  ##   assert(test[int](3) == 3)
  ##   assert(test[string]("xyz") == 0)
template `isnot` *(x, y: expr): expr {.immediate.} = not (x is y)
  ## Negated version of `is`. Equivalent to ``not(x is y)``.

proc `of` *[T, S](x: T, y: S): bool {.magic: "Of", noSideEffect.}
  ## Checks if `x` has a type of `y`
  ##
  ## .. code-block:: Nim
  ##   assert(FloatingPointError of Exception)
  ##   assert(DivByZeroError of Exception)

proc cmp*[T](x, y: T): int {.procvar.} =
  ## Generic compare proc. Returns a value < 0 iff x < y, a value > 0 iff x > y
  ## and 0 iff x == y. This is useful for writing generic algorithms without
  ## performance loss. This generic implementation uses the `==` and `<`
  ## operators.
  ##
  ## .. code-block:: Nim
  ##  import algorithm
  ##  echo sorted(@[4,2,6,5,8,7], cmp[int])
  if x == y: return 0
  if x < y: return -1
  return 1

proc cmp*(x, y: string): int {.noSideEffect, procvar.}
  ## Compare proc for strings. More efficient than the generic version.

proc `@` * [IDX, T](a: array[IDX, T]): seq[T] {.
  magic: "ArrToSeq", nosideeffect.}
  ## turns an array into a sequence. This most often useful for constructing
  ## sequences with the array constructor: ``@[1, 2, 3]`` has the type
  ## ``seq[int]``, while ``[1, 2, 3]`` has the type ``array[0..2, int]``.

proc setLen*[T](s: var seq[T], newlen: Natural) {.
  magic: "SetLengthSeq", noSideEffect.}
  ## sets the length of `s` to `newlen`.
  ## ``T`` may be any sequence type.
  ## If the current length is greater than the new length,
  ## ``s`` will be truncated. `s` cannot be nil! To initialize a sequence with
  ## a size, use ``newSeq`` instead.

proc setLen*(s: var string, newlen: Natural) {.
  magic: "SetLengthStr", noSideEffect.}
  ## sets the length of `s` to `newlen`.
  ## If the current length is greater than the new length,
  ## ``s`` will be truncated. `s` cannot be nil! To initialize a string with
  ## a size, use ``newString`` instead.
  ##
  ## .. code-block:: Nim
  ##  var myS = "Nim is great!!"
  ##  myS.setLen(3)
  ##  echo myS, " is fantastic!!"

proc newString*(len: Natural): string {.
  magic: "NewString", importc: "mnewString", noSideEffect.}
  ## returns a new string of length ``len`` but with uninitialized
  ## content. One needs to fill the string character after character
  ## with the index operator ``s[i]``. This procedure exists only for
  ## optimization purposes; the same effect can be achieved with the
  ## ``&`` operator or with ``add``.

proc newStringOfCap*(cap: Natural): string {.
  magic: "NewStringOfCap", importc: "rawNewString", noSideEffect.}
  ## returns a new string of length ``0`` but with capacity `cap`.This
  ## procedure exists only for optimization purposes; the same effect can
  ## be achieved with the ``&`` operator or with ``add``.

proc `&` * (x: string, y: char): string {.
  magic: "ConStrStr", noSideEffect, merge.}
  ## Concatenates `x` with `y`
  ##
  ## .. code-block:: Nim
  ##   assert("ab" & 'c' == "abc")
proc `&` * (x, y: char): string {.
  magic: "ConStrStr", noSideEffect, merge.}
  ## Concatenates `x` and `y` into a string
  ##
  ## .. code-block:: Nim
  ##   assert('a' & 'b' == "ab")
proc `&` * (x, y: string): string {.
  magic: "ConStrStr", noSideEffect, merge.}
  ## Concatenates `x` and `y`
  ##
  ## .. code-block:: Nim
  ##   assert("ab" & "cd" == "abcd")
proc `&` * (x: char, y: string): string {.
  magic: "ConStrStr", noSideEffect, merge.}
  ## Concatenates `x` with `y`
  ##
  ## .. code-block:: Nim
  ##   assert('a' & "bc" == "abc")

# implementation note: These must all have the same magic value "ConStrStr" so
# that the merge optimization works properly.

proc add*(x: var string, y: char) {.magic: "AppendStrCh", noSideEffect.}
  ## Appends `y` to `x` in place
  ##
  ## .. code-block:: Nim
  ##   var tmp = ""
  ##   tmp.add('a')
  ##   tmp.add('b')
  ##   assert(tmp == "ab")
proc add*(x: var string, y: string) {.magic: "AppendStrStr", noSideEffect.}
  ## Concatenates `x` and `y` in place
  ##
  ## .. code-block:: Nim
  ##   var tmp = ""
  ##   tmp.add("ab")
  ##   tmp.add("cd")
  ##   assert(tmp == "abcd")

type
  Endianness* = enum ## is a type describing the endianness of a processor.
    littleEndian, bigEndian

const
  isMainModule* {.magic: "IsMainModule".}: bool = false
    ## is true only when accessed in the main module. This works thanks to
    ## compiler magic. It is useful to embed testing code in a module.

  CompileDate* {.magic: "CompileDate"}: string = "0000-00-00"
    ## is the date of compilation as a string of the form
    ## ``YYYY-MM-DD``. This works thanks to compiler magic.

  CompileTime* {.magic: "CompileTime"}: string = "00:00:00"
    ## is the time of compilation as a string of the form
    ## ``HH:MM:SS``. This works thanks to compiler magic.

  cpuEndian* {.magic: "CpuEndian"}: Endianness = littleEndian
    ## is the endianness of the target CPU. This is a valuable piece of
    ## information for low-level code only. This works thanks to compiler
    ## magic.

  hostOS* {.magic: "HostOS".}: string = ""
    ## a string that describes the host operating system. Possible values:
    ## "windows", "macosx", "linux", "netbsd", "freebsd", "openbsd", "solaris",
    ## "aix", "standalone".

  hostCPU* {.magic: "HostCPU".}: string = ""
    ## a string that describes the host CPU. Possible values:
    ## "i386", "alpha", "powerpc", "powerpc64", "powerpc64el", "sparc",
    ## "amd64", "mips", "mipsel", "arm", "arm64".

  seqShallowFlag = low(int)

when defined(nimKnowsNimvm):
  let nimvm* {.magic: "Nimvm".}: bool = false
    ## may be used only in "when" expression.
    ## It is true in Nim VM context and false otherwise
else:
  const nimvm*: bool = false

proc compileOption*(option: string): bool {.
  magic: "CompileOption", noSideEffect.}
  ## can be used to determine an on|off compile-time option. Example:
  ##
  ## .. code-block:: nim
  ##   when compileOption("floatchecks"):
  ##     echo "compiled with floating point NaN and Inf checks"

proc compileOption*(option, arg: string): bool {.
  magic: "CompileOptionArg", noSideEffect.}
  ## can be used to determine an enum compile-time option. Example:
  ##
  ## .. code-block:: nim
  ##   when compileOption("opt", "size") and compileOption("gc", "boehm"):
  ##     echo "compiled with optimization for size and uses Boehm's GC"

const
  hasThreadSupport = compileOption("threads") and not defined(nimscript)
  hasSharedHeap = defined(boehmgc) or defined(gogc) # don't share heaps; every thread has its own
  taintMode = compileOption("taintmode")

when defined(boehmgc):
  when defined(windows):
    const boehmLib = "boehmgc.dll"
  elif defined(macosx):
    const boehmLib = "libgc.dylib"
  else:
    const boehmLib = "libgc.so.1"
  {.pragma: boehmGC, noconv, dynlib: boehmLib.}

when taintMode:
  type TaintedString* = distinct string ## a distinct string type that
                                        ## is `tainted`:idx:. It is an alias for
                                        ## ``string`` if the taint mode is not
                                        ## turned on. Use the ``-d:taintMode``
                                        ## command line switch to turn the taint
                                        ## mode on.

  proc len*(s: TaintedString): int {.borrow.}
else:
  type TaintedString* = string          ## a distinct string type that
                                        ## is `tainted`:idx:. It is an alias for
                                        ## ``string`` if the taint mode is not
                                        ## turned on. Use the ``-d:taintMode``
                                        ## command line switch to turn the taint
                                        ## mode on.

when defined(profiler):
  proc nimProfile() {.compilerProc, noinline.}
when hasThreadSupport:
  {.pragma: rtlThreadVar, threadvar.}
else:
  {.pragma: rtlThreadVar.}

const
  QuitSuccess* = 0
    ## is the value that should be passed to `quit <#quit>`_ to indicate
    ## success.

  QuitFailure* = 1
    ## is the value that should be passed to `quit <#quit>`_ to indicate
    ## failure.

var programResult* {.exportc: "nim_program_result".}: int
  ## modify this variable to specify the exit code of the program
  ## under normal circumstances. When the program is terminated
  ## prematurely using ``quit``, this value is ignored.

proc quit*(errorcode: int = QuitSuccess) {.
  magic: "Exit", importc: "exit", header: "<stdlib.h>", noreturn.}
  ## Stops the program immediately with an exit code.
  ##
  ## Before stopping the program the "quit procedures" are called in the
  ## opposite order they were added with `addQuitProc <#addQuitProc>`_.
  ## ``quit`` never returns and ignores any exception that may have been raised
  ## by the quit procedures.  It does *not* call the garbage collector to free
  ## all the memory, unless a quit procedure calls `GC_fullCollect
  ## <#GC_fullCollect>`_.
  ##
  ## The proc ``quit(QuitSuccess)`` is called implicitly when your nim
  ## program finishes without incident. A raised unhandled exception is
  ## equivalent to calling ``quit(QuitFailure)``.
  ##
  ## Note that this is a *runtime* call and using ``quit`` inside a macro won't
  ## have any compile time effect. If you need to stop the compiler inside a
  ## macro, use the `error <manual.html#error-pragma>`_ or `fatal
  ## <manual.html#fatal-pragma>`_ pragmas.

template sysAssert(cond: bool, msg: string) =
  when defined(useSysAssert):
    if not cond:
      echo "[SYSASSERT] ", msg
      quit 1

const hasAlloc = (hostOS != "standalone" or not defined(nogc)) and not defined(nimscript)

when not defined(JS) and not defined(nimscript) and hostOS != "standalone":
  include "system/cgprocs"
when not defined(JS) and not defined(nimscript) and hasAlloc:
  proc setStackBottom(theStackBottom: pointer) {.compilerRtl, noinline, benign.}
  proc addChar(s: NimString, c: char): NimString {.compilerProc, benign.}

proc add *[T](x: var seq[T], y: T) {.magic: "AppendSeqElem", noSideEffect.}
proc add *[T](x: var seq[T], y: openArray[T]) {.noSideEffect.} =
  ## Generic proc for adding a data item `y` to a container `x`.
  ## For containers that have an order, `add` means *append*. New generic
  ## containers should also call their adding proc `add` for consistency.
  ## Generic code becomes much easier to write if the Nim naming scheme is
  ## respected.
  ##
  ## .. code-block:: nim
  ##   var s: seq[string] = @["test2","test2"]
  ##   s.add("test") #=> @[test2, test2, test]
  let xl = x.len
  setLen(x, xl + y.len)
  for i in 0..high(y): x[xl+i] = y[i]

proc shallowCopy*[T](x: var T, y: T) {.noSideEffect, magic: "ShallowCopy".}
  ## use this instead of `=` for a `shallow copy`:idx:. The shallow copy
  ## only changes the semantics for sequences and strings (and types which
  ## contain those). Be careful with the changed semantics though! There
  ## is a reason why the default assignment does a deep copy of sequences
  ## and strings.

proc del*[T](x: var seq[T], i: Natural) {.noSideEffect.} =
  ## deletes the item at index `i` by putting ``x[high(x)]`` into position `i`.
  ## This is an O(1) operation.
  ##
  ## .. code-block:: nim
  ##  var i = @[1,2,3,4,5]
  ##  i.del(2) #=> @[1, 2, 5, 4]
  let xl = x.len - 1
  shallowCopy(x[i], x[xl])
  setLen(x, xl)

proc delete*[T](x: var seq[T], i: Natural) {.noSideEffect.} =
  ## deletes the item at index `i` by moving ``x[i+1..]`` by one position.
  ## This is an O(n) operation.
  ##
  ## .. code-block:: nim
  ##  var i = @[1,2,3,4,5]
  ##  i.delete(2) #=> @[1, 2, 4, 5]
  template defaultImpl =
    let xl = x.len
    for j in i..xl-2: shallowCopy(x[j], x[j+1])
    setLen(x, xl-1)

  when nimvm:
    defaultImpl()
  else:
    when defined(js):
      {.emit: "`x`[`x`_Idx].splice(`i`, 1);".}
    else:
      defaultImpl()

proc insert*[T](x: var seq[T], item: T, i = 0.Natural) {.noSideEffect.} =
  ## inserts `item` into `x` at position `i`.
  ##
  ## .. code-block:: nim
  ##  var i = @[1,2,3,4,5]
  ##  i.insert(2,4) #=> @[1, 2, 3, 4, 2, 5]
  template defaultImpl =
    let xl = x.len
    setLen(x, xl+1)
    var j = xl-1
    while j >= i:
      shallowCopy(x[j+1], x[j])
      dec(j)
  when nimvm:
    defaultImpl()
  else:
    when defined(js):
      var it : T
      {.emit: "`x`[`x`_Idx].splice(`i`, 0, `it`);".}
    else:
      defaultImpl()
  x[i] = item

proc repr*[T](x: T): string {.magic: "Repr", noSideEffect.}
  ## takes any Nim variable and returns its string representation. It
  ## works even for complex data graphs with cycles. This is a great
  ## debugging tool.
  ##
  ## .. code-block:: nim
  ##  var s: seq[string] = @["test2","test2"]
  ##  var i = @[1,2,3,4,5]
  ##  repr(s) #=> 0x1055eb050[0x1055ec050"test2", 0x1055ec078"test2"]
  ##  repr(i) #=> 0x1055ed050[1, 2, 3, 4, 5]

type
  ByteAddress* = int
    ## is the signed integer type that should be used for converting
    ## pointers to integer addresses for readability.

  BiggestInt* = int64
    ## is an alias for the biggest signed integer type the Nim compiler
    ## supports. Currently this is ``int64``, but it is platform-dependant
    ## in general.

  BiggestFloat* = float64
    ## is an alias for the biggest floating point type the Nim
    ## compiler supports. Currently this is ``float64``, but it is
    ## platform-dependant in general.

{.deprecated: [TAddress: ByteAddress].}

when defined(windows):
  type
    clong* {.importc: "long", nodecl.} = int32
      ## This is the same as the type ``long`` in *C*.
    culong* {.importc: "unsigned long", nodecl.} = uint32
      ## This is the same as the type ``unsigned long`` in *C*.
else:
  type
    clong* {.importc: "long", nodecl.} = int
      ## This is the same as the type ``long`` in *C*.
    culong* {.importc: "unsigned long", nodecl.} = uint
      ## This is the same as the type ``unsigned long`` in *C*.

type # these work for most platforms:
  cchar* {.importc: "char", nodecl.} = char
    ## This is the same as the type ``char`` in *C*.
  cschar* {.importc: "signed char", nodecl.} = int8
    ## This is the same as the type ``signed char`` in *C*.
  cshort* {.importc: "short", nodecl.} = int16
    ## This is the same as the type ``short`` in *C*.
  cint* {.importc: "int", nodecl.} = int32
    ## This is the same as the type ``int`` in *C*.
  csize* {.importc: "size_t", nodecl.} = int
    ## This is the same as the type ``size_t`` in *C*.
  clonglong* {.importc: "long long", nodecl.} = int64
    ## This is the same as the type ``long long`` in *C*.
  cfloat* {.importc: "float", nodecl.} = float32
    ## This is the same as the type ``float`` in *C*.
  cdouble* {.importc: "double", nodecl.} = float64
    ## This is the same as the type ``double`` in *C*.
  clongdouble* {.importc: "long double", nodecl.} = BiggestFloat
    ## This is the same as the type ``long double`` in *C*.
    ## This C type is not supported by Nim's code generator

  cuchar* {.importc: "unsigned char", nodecl.} = char
    ## This is the same as the type ``unsigned char`` in *C*.
  cushort* {.importc: "unsigned short", nodecl.} = uint16
    ## This is the same as the type ``unsigned short`` in *C*.
  cuint* {.importc: "unsigned int", nodecl.} = uint32
    ## This is the same as the type ``unsigned int`` in *C*.
  culonglong* {.importc: "unsigned long long", nodecl.} = uint64
    ## This is the same as the type ``unsigned long long`` in *C*.

  cstringArray* {.importc: "char**", nodecl.} = ptr
    array [0..ArrayDummySize, cstring]
    ## This is binary compatible to the type ``char**`` in *C*. The array's
    ## high value is large enough to disable bounds checking in practice.
    ## Use `cstringArrayToSeq` to convert it into a ``seq[string]``.

  PFloat32* = ptr float32 ## an alias for ``ptr float32``
  PFloat64* = ptr float64 ## an alias for ``ptr float64``
  PInt64* = ptr int64 ## an alias for ``ptr int64``
  PInt32* = ptr int32 ## an alias for ``ptr int32``

proc toFloat*(i: int): float {.
  magic: "ToFloat", noSideEffect, importc: "toFloat".}
  ## converts an integer `i` into a ``float``. If the conversion
  ## fails, `EInvalidValue` is raised. However, on most platforms the
  ## conversion cannot fail.

proc toBiggestFloat*(i: BiggestInt): BiggestFloat {.
  magic: "ToBiggestFloat", noSideEffect, importc: "toBiggestFloat".}
  ## converts an biggestint `i` into a ``biggestfloat``. If the conversion
  ## fails, `EInvalidValue` is raised. However, on most platforms the
  ## conversion cannot fail.

proc toInt*(f: float): int {.
  magic: "ToInt", noSideEffect, importc: "toInt".}
  ## converts a floating point number `f` into an ``int``. Conversion
  ## rounds `f` if it does not contain an integer value. If the conversion
  ## fails (because `f` is infinite for example), `EInvalidValue` is raised.

proc toBiggestInt*(f: BiggestFloat): BiggestInt {.
  magic: "ToBiggestInt", noSideEffect, importc: "toBiggestInt".}
  ## converts a biggestfloat `f` into a ``biggestint``. Conversion
  ## rounds `f` if it does not contain an integer value. If the conversion
  ## fails (because `f` is infinite for example), `EInvalidValue` is raised.

proc addQuitProc*(QuitProc: proc() {.noconv.}) {.
  importc: "atexit", header: "<stdlib.h>".}
  ## Adds/registers a quit procedure.
  ##
  ## Each call to ``addQuitProc`` registers another quit procedure. Up to 30
  ## procedures can be registered. They are executed on a last-in, first-out
  ## basis (that is, the last function registered is the first to be executed).
  ## ``addQuitProc`` raises an EOutOfIndex exception if ``QuitProc`` cannot be
  ## registered.

# Support for addQuitProc() is done by Ansi C's facilities here.
# In case of an unhandled exeption the exit handlers should
# not be called explicitly! The user may decide to do this manually though.

proc copy*(s: string, first = 0): string {.
  magic: "CopyStr", importc: "copyStr", noSideEffect, deprecated.}
proc copy*(s: string, first, last: int): string {.
  magic: "CopyStrLast", importc: "copyStrLast", noSideEffect,
  deprecated.}
  ## copies a slice of `s` into a new string and returns this new
  ## string. The bounds `first` and `last` denote the indices of
  ## the first and last characters that shall be copied. If ``last``
  ## is omitted, it is treated as ``high(s)``.
  ## **Deprecated since version 0.8.12**: Use ``substr`` instead.

proc substr*(s: string, first = 0): string {.
  magic: "CopyStr", importc: "copyStr", noSideEffect.}
proc substr*(s: string, first, last: int): string {.
  magic: "CopyStrLast", importc: "copyStrLast", noSideEffect.}
  ## copies a slice of `s` into a new string and returns this new
  ## string. The bounds `first` and `last` denote the indices of
  ## the first and last characters that shall be copied. If ``last``
  ## is omitted, it is treated as ``high(s)``. If ``last >= s.len``, ``s.len``
  ## is used instead: This means ``substr`` can also be used to `cut`:idx:
  ## or `limit`:idx: a string's length.

when not defined(nimscript):
  proc zeroMem*(p: pointer, size: Natural) {.importc, noDecl, benign.}
    ## overwrites the contents of the memory at ``p`` with the value 0.
    ## Exactly ``size`` bytes will be overwritten. Like any procedure
    ## dealing with raw memory this is *unsafe*.

  proc copyMem*(dest, source: pointer, size: Natural) {.
    importc: "memcpy", header: "<string.h>", benign.}
    ## copies the contents from the memory at ``source`` to the memory
    ## at ``dest``. Exactly ``size`` bytes will be copied. The memory
    ## regions may not overlap. Like any procedure dealing with raw
    ## memory this is *unsafe*.

  proc moveMem*(dest, source: pointer, size: Natural) {.
    importc: "memmove", header: "<string.h>", benign.}
    ## copies the contents from the memory at ``source`` to the memory
    ## at ``dest``. Exactly ``size`` bytes will be copied. The memory
    ## regions may overlap, ``moveMem`` handles this case appropriately
    ## and is thus somewhat more safe than ``copyMem``. Like any procedure
    ## dealing with raw memory this is still *unsafe*, though.

  proc equalMem*(a, b: pointer, size: Natural): bool {.
    importc: "equalMem", noDecl, noSideEffect.}
    ## compares the memory blocks ``a`` and ``b``. ``size`` bytes will
    ## be compared. If the blocks are equal, true is returned, false
    ## otherwise. Like any procedure dealing with raw memory this is
    ## *unsafe*.

  when hasAlloc:
    proc alloc*(size: Natural): pointer {.noconv, rtl, tags: [], benign.}
      ## allocates a new memory block with at least ``size`` bytes. The
      ## block has to be freed with ``realloc(block, 0)`` or
      ## ``dealloc(block)``. The block is not initialized, so reading
      ## from it before writing to it is undefined behaviour!
      ## The allocated memory belongs to its allocating thread!
      ## Use `allocShared` to allocate from a shared heap.
    proc createU*(T: typedesc, size = 1.Positive): ptr T {.inline, benign.} =
      ## allocates a new memory block with at least ``T.sizeof * size``
      ## bytes. The block has to be freed with ``resize(block, 0)`` or
      ## ``free(block)``. The block is not initialized, so reading
      ## from it before writing to it is undefined behaviour!
      ## The allocated memory belongs to its allocating thread!
      ## Use `createSharedU` to allocate from a shared heap.
      cast[ptr T](alloc(T.sizeof * size))
    proc alloc0*(size: Natural): pointer {.noconv, rtl, tags: [], benign.}
      ## allocates a new memory block with at least ``size`` bytes. The
      ## block has to be freed with ``realloc(block, 0)`` or
      ## ``dealloc(block)``. The block is initialized with all bytes
      ## containing zero, so it is somewhat safer than ``alloc``.
      ## The allocated memory belongs to its allocating thread!
      ## Use `allocShared0` to allocate from a shared heap.
    proc create*(T: typedesc, size = 1.Positive): ptr T {.inline, benign.} =
      ## allocates a new memory block with at least ``T.sizeof * size``
      ## bytes. The block has to be freed with ``resize(block, 0)`` or
      ## ``free(block)``. The block is initialized with all bytes
      ## containing zero, so it is somewhat safer than ``createU``.
      ## The allocated memory belongs to its allocating thread!
      ## Use `createShared` to allocate from a shared heap.
      cast[ptr T](alloc0(sizeof(T) * size))
    proc realloc*(p: pointer, newSize: Natural): pointer {.noconv, rtl, tags: [],
                                                           benign.}
      ## grows or shrinks a given memory block. If p is **nil** then a new
      ## memory block is returned. In either way the block has at least
      ## ``newSize`` bytes. If ``newSize == 0`` and p is not **nil**
      ## ``realloc`` calls ``dealloc(p)``. In other cases the block has to
      ## be freed with ``dealloc``.
      ## The allocated memory belongs to its allocating thread!
      ## Use `reallocShared` to reallocate from a shared heap.
    proc resize*[T](p: ptr T, newSize: Natural): ptr T {.inline, benign.} =
      ## grows or shrinks a given memory block. If p is **nil** then a new
      ## memory block is returned. In either way the block has at least
      ## ``T.sizeof * newSize`` bytes. If ``newSize == 0`` and p is not
      ## **nil** ``resize`` calls ``free(p)``. In other cases the block
      ## has to be freed with ``free``. The allocated memory belongs to
      ## its allocating thread!
      ## Use `resizeShared` to reallocate from a shared heap.
      cast[ptr T](realloc(p, T.sizeof * newSize))
    proc dealloc*(p: pointer) {.noconv, rtl, tags: [], benign.}
      ## frees the memory allocated with ``alloc``, ``alloc0`` or
      ## ``realloc``. This procedure is dangerous! If one forgets to
      ## free the memory a leak occurs; if one tries to access freed
      ## memory (or just freeing it twice!) a core dump may happen
      ## or other memory may be corrupted.
      ## The freed memory must belong to its allocating thread!
      ## Use `deallocShared` to deallocate from a shared heap.

    proc allocShared*(size: Natural): pointer {.noconv, rtl, benign.}
      ## allocates a new memory block on the shared heap with at
      ## least ``size`` bytes. The block has to be freed with
      ## ``reallocShared(block, 0)`` or ``deallocShared(block)``. The block
      ## is not initialized, so reading from it before writing to it is
      ## undefined behaviour!
    proc createSharedU*(T: typedesc, size = 1.Positive): ptr T {.inline,
                                                                 benign.} =
      ## allocates a new memory block on the shared heap with at
      ## least ``T.sizeof * size`` bytes. The block has to be freed with
      ## ``resizeShared(block, 0)`` or ``freeShared(block)``. The block
      ## is not initialized, so reading from it before writing to it is
      ## undefined behaviour!
      cast[ptr T](allocShared(T.sizeof * size))
    proc allocShared0*(size: Natural): pointer {.noconv, rtl, benign.}
      ## allocates a new memory block on the shared heap with at
      ## least ``size`` bytes. The block has to be freed with
      ## ``reallocShared(block, 0)`` or ``deallocShared(block)``.
      ## The block is initialized with all bytes
      ## containing zero, so it is somewhat safer than ``allocShared``.
    proc createShared*(T: typedesc, size = 1.Positive): ptr T {.inline.} =
      ## allocates a new memory block on the shared heap with at
      ## least ``T.sizeof * size`` bytes. The block has to be freed with
      ## ``resizeShared(block, 0)`` or ``freeShared(block)``.
      ## The block is initialized with all bytes
      ## containing zero, so it is somewhat safer than ``createSharedU``.
      cast[ptr T](allocShared0(T.sizeof * size))
    proc reallocShared*(p: pointer, newSize: Natural): pointer {.noconv, rtl,
                                                                 benign.}
      ## grows or shrinks a given memory block on the heap. If p is **nil**
      ## then a new memory block is returned. In either way the block has at
      ## least ``newSize`` bytes. If ``newSize == 0`` and p is not **nil**
      ## ``reallocShared`` calls ``deallocShared(p)``. In other cases the
      ## block has to be freed with ``deallocShared``.
    proc resizeShared*[T](p: ptr T, newSize: Natural): ptr T {.inline.} =
      ## grows or shrinks a given memory block on the heap. If p is **nil**
      ## then a new memory block is returned. In either way the block has at
      ## least ``T.sizeof * newSize`` bytes. If ``newSize == 0`` and p is
      ## not **nil** ``resizeShared`` calls ``freeShared(p)``. In other
      ## cases the block has to be freed with ``freeShared``.
      cast[ptr T](reallocShared(p, T.sizeof * newSize))
    proc deallocShared*(p: pointer) {.noconv, rtl, benign.}
      ## frees the memory allocated with ``allocShared``, ``allocShared0`` or
      ## ``reallocShared``. This procedure is dangerous! If one forgets to
      ## free the memory a leak occurs; if one tries to access freed
      ## memory (or just freeing it twice!) a core dump may happen
      ## or other memory may be corrupted.
    proc freeShared*[T](p: ptr T) {.inline, benign.} =
      ## frees the memory allocated with ``createShared``, ``createSharedU`` or
      ## ``resizeShared``. This procedure is dangerous! If one forgets to
      ## free the memory a leak occurs; if one tries to access freed
      ## memory (or just freeing it twice!) a core dump may happen
      ## or other memory may be corrupted.
      deallocShared(p)

proc swap*[T](a, b: var T) {.magic: "Swap", noSideEffect.}
  ## swaps the values `a` and `b`. This is often more efficient than
  ## ``tmp = a; a = b; b = tmp``. Particularly useful for sorting algorithms.

template `>=%` *(x, y: expr): expr {.immediate.} = y <=% x
  ## treats `x` and `y` as unsigned and compares them.
  ## Returns true iff ``unsigned(x) >= unsigned(y)``.

template `>%` *(x, y: expr): expr {.immediate.} = y <% x
  ## treats `x` and `y` as unsigned and compares them.
  ## Returns true iff ``unsigned(x) > unsigned(y)``.

proc `$`*(x: int): string {.magic: "IntToStr", noSideEffect.}
  ## The stringify operator for an integer argument. Returns `x`
  ## converted to a decimal string. ``$`` is Nim's general way of
  ## spelling `toString`:idx:.

proc `$`*(x: int64): string {.magic: "Int64ToStr", noSideEffect.}
  ## The stringify operator for an integer argument. Returns `x`
  ## converted to a decimal string.

when not defined(nimscript):
  when not defined(JS) and hasAlloc:
    proc `$` *(x: uint64): string {.noSideEffect.}
      ## The stringify operator for an unsigned integer argument. Returns `x`
      ## converted to a decimal string.

proc `$` *(x: float): string {.magic: "FloatToStr", noSideEffect.}
  ## The stringify operator for a float argument. Returns `x`
  ## converted to a decimal string.

proc `$` *(x: bool): string {.magic: "BoolToStr", noSideEffect.}
  ## The stringify operator for a boolean argument. Returns `x`
  ## converted to the string "false" or "true".

proc `$` *(x: char): string {.magic: "CharToStr", noSideEffect.}
  ## The stringify operator for a character argument. Returns `x`
  ## converted to a string.

proc `$` *(x: cstring): string {.magic: "CStrToStr", noSideEffect.}
  ## The stringify operator for a CString argument. Returns `x`
  ## converted to a string.

proc `$` *(x: string): string {.magic: "StrToStr", noSideEffect.}
  ## The stringify operator for a string argument. Returns `x`
  ## as it is. This operator is useful for generic code, so
  ## that ``$expr`` also works if ``expr`` is already a string.

proc `$` *[Enum: enum](x: Enum): string {.magic: "EnumToStr", noSideEffect.}
  ## The stringify operator for an enumeration argument. This works for
  ## any enumeration type thanks to compiler magic. If
  ## a ``$`` operator for a concrete enumeration is provided, this is
  ## used instead. (In other words: *Overwriting* is possible.)

# undocumented:
proc getRefcount*[T](x: ref T): int {.importc: "getRefcount", noSideEffect.}
proc getRefcount*(x: string): int {.importc: "getRefcount", noSideEffect.}
proc getRefcount*[T](x: seq[T]): int {.importc: "getRefcount", noSideEffect.}
  ## retrieves the reference count of an heap-allocated object. The
  ## value is implementation-dependent.


const
  Inf* {.magic: "Inf".} = 1.0 / 0.0
    ## contains the IEEE floating point value of positive infinity.
  NegInf* {.magic: "NegInf".} = -Inf
    ## contains the IEEE floating point value of negative infinity.
  NaN* {.magic: "NaN".} = 0.0 / 0.0
    ## contains an IEEE floating point value of *Not A Number*. Note
    ## that you cannot compare a floating point value to this value
    ## and expect a reasonable result - use the `classify` procedure
    ## in the module ``math`` for checking for NaN.
  NimMajor*: int = 0
    ## is the major number of Nim's version.

  NimMinor*: int = 12
    ## is the minor number of Nim's version.

  NimPatch*: int = 0
    ## is the patch number of Nim's version.

  NimVersion*: string = $NimMajor & "." & $NimMinor & "." & $NimPatch
    ## is the version of Nim as a string.

{.deprecated: [TEndian: Endianness, NimrodVersion: NimVersion,
    NimrodMajor: NimMajor, NimrodMinor: NimMinor, NimrodPatch: NimPatch].}

# GC interface:

when not defined(nimscript) and hasAlloc:
  proc getOccupiedMem*(): int {.rtl.}
    ## returns the number of bytes that are owned by the process and hold data.

  proc getFreeMem*(): int {.rtl.}
    ## returns the number of bytes that are owned by the process, but do not
    ## hold any meaningful data.

  proc getTotalMem*(): int {.rtl.}
    ## returns the number of bytes that are owned by the process.

  when hasThreadSupport:
    proc getOccupiedSharedMem*(): int {.rtl.}
      ## returns the number of bytes that are owned by the process
      ## on the shared heap and hold data. This is only available when
      ## threads are enabled.

    proc getFreeSharedMem*(): int {.rtl.}
      ## returns the number of bytes that are owned by the
      ## process on the shared heap, but do not hold any meaningful data.
      ## This is only available when threads are enabled.

    proc getTotalSharedMem*(): int {.rtl.}
      ## returns the number of bytes on the shared heap that are owned by the
      ## process. This is only available when threads are enabled.

when sizeof(int) <= 2:
  type IntLikeForCount = int|int8|int16|char|bool|uint8|enum
else:
  type IntLikeForCount = int|int8|int16|int32|char|bool|uint8|uint16|enum

iterator countdown*[T](a, b: T, step = 1): T {.inline.} =
  ## Counts from ordinal value `a` down to `b` (inclusive) with the given
  ## step count. `T` may be any ordinal type, `step` may only
  ## be positive. **Note**: This fails to count to ``low(int)`` if T = int for
  ## efficiency reasons.
  when T is IntLikeForCount:
    var res = int(a)
    while res >= int(b):
      yield T(res)
      dec(res, step)
  else:
    var res = a
    while res >= b:
      yield res
      dec(res, step)

template countupImpl(incr: stmt) {.immediate, dirty.} =
  when T is IntLikeForCount:
    var res = int(a)
    while res <= int(b):
      yield T(res)
      incr
  else:
    var res: T = T(a)
    while res <= b:
      yield res
      incr

iterator countup*[S, T](a: S, b: T, step = 1): T {.inline.} =
  ## Counts from ordinal value `a` up to `b` (inclusive) with the given
  ## step count. `S`, `T` may be any ordinal type, `step` may only
  ## be positive. **Note**: This fails to count to ``high(int)`` if T = int for
  ## efficiency reasons.
  countupImpl:
    inc(res, step)

iterator `..`*[S, T](a: S, b: T): T {.inline.} =
  ## An alias for `countup`.
  countupImpl:
    inc(res)

iterator `||`*[S, T](a: S, b: T, annotation=""): T {.
  inline, magic: "OmpParFor", sideEffect.} =
  ## parallel loop iterator. Same as `..` but the loop may run in parallel.
  ## `annotation` is an additional annotation for the code generator to use.
  ## Note that the compiler maps that to
  ## the ``#pragma omp parallel for`` construct of `OpenMP`:idx: and as
  ## such isn't aware of the parallelism in your code! Be careful! Later
  ## versions of ``||`` will get proper support by Nim's code generator
  ## and GC.
  discard

{.push stackTrace:off.}
proc min*(x, y: int): int {.magic: "MinI", noSideEffect.} =
  if x <= y: x else: y
proc min*(x, y: int8): int8 {.magic: "MinI", noSideEffect.} =
  if x <= y: x else: y
proc min*(x, y: int16): int16 {.magic: "MinI", noSideEffect.} =
  if x <= y: x else: y
proc min*(x, y: int32): int32 {.magic: "MinI", noSideEffect.} =
  if x <= y: x else: y
proc min*(x, y: int64): int64 {.magic: "MinI", noSideEffect.} =
  ## The minimum value of two integers.
  if x <= y: x else: y

proc min*[T](x: varargs[T]): T =
  ## The minimum value of `x`. ``T`` needs to have a ``<`` operator.
  result = x[0]
  for i in 1..high(x):
    if x[i] < result: result = x[i]

proc max*(x, y: int): int {.magic: "MaxI", noSideEffect.} =
  if y <= x: x else: y
proc max*(x, y: int8): int8 {.magic: "MaxI", noSideEffect.} =
  if y <= x: x else: y
proc max*(x, y: int16): int16 {.magic: "MaxI", noSideEffect.} =
  if y <= x: x else: y
proc max*(x, y: int32): int32 {.magic: "MaxI", noSideEffect.} =
  if y <= x: x else: y
proc max*(x, y: int64): int64 {.magic: "MaxI", noSideEffect.} =
  ## The maximum value of two integers.
  if y <= x: x else: y

proc max*[T](x: varargs[T]): T =
  ## The maximum value of `x`. ``T`` needs to have a ``<`` operator.
  result = x[0]
  for i in 1..high(x):
    if result < x[i]: result = x[i]

proc abs*(x: float): float {.magic: "AbsF64", noSideEffect.} =
  if x < 0.0: -x else: x
proc min*(x, y: float): float {.magic: "MinF64", noSideEffect.} =
  if x <= y: x else: y
proc max*(x, y: float): float {.magic: "MaxF64", noSideEffect.} =
  if y <= x: x else: y
{.pop.}

proc clamp*[T](x, a, b: T): T =
  ## limits the value ``x`` within the interval [a, b]
  ##
  ## .. code-block:: Nim
  ##   assert((1.4).clamp(0.0, 1.0) == 1.0)
  ##   assert((0.5).clamp(0.0, 1.0) == 0.5)
  if x < a: return a
  if x > b: return b
  return x

iterator items*[T](a: openArray[T]): T {.inline.} =
  ## iterates over each item of `a`.
  var i = 0
  while i < len(a):
    yield a[i]
    inc(i)

iterator mitems*[T](a: var openArray[T]): var T {.inline.} =
  ## iterates over each item of `a` so that you can modify the yielded value.
  var i = 0
  while i < len(a):
    yield a[i]
    inc(i)

iterator items*[IX, T](a: array[IX, T]): T {.inline.} =
  ## iterates over each item of `a`.
  var i = low(IX)
  if i <= high(IX):
    while true:
      yield a[i]
      if i >= high(IX): break
      inc(i)

iterator mitems*[IX, T](a: var array[IX, T]): var T {.inline.} =
  ## iterates over each item of `a` so that you can modify the yielded value.
  var i = low(IX)
  if i <= high(IX):
    while true:
      yield a[i]
      if i >= high(IX): break
      inc(i)

iterator items*[T](a: set[T]): T {.inline.} =
  ## iterates over each element of `a`. `items` iterates only over the
  ## elements that are really in the set (and not over the ones the set is
  ## able to hold).
  var i = low(T).int
  while i <= high(T).int:
    if T(i) in a: yield T(i)
    inc(i)

iterator items*(a: cstring): char {.inline.} =
  ## iterates over each item of `a`.
  var i = 0
  while a[i] != '\0':
    yield a[i]
    inc(i)

iterator mitems*(a: var cstring): var char {.inline.} =
  ## iterates over each item of `a` so that you can modify the yielded value.
  var i = 0
  while a[i] != '\0':
    yield a[i]
    inc(i)

iterator items*(E: typedesc[enum]): E =
  ## iterates over the values of the enum ``E``.
  for v in low(E)..high(E):
    yield v

iterator items*[T](s: Slice[T]): T =
  ## iterates over the slice `s`, yielding each value between `s.a` and `s.b`
  ## (inclusively).
  for x in s.a..s.b:
    yield x

iterator pairs*[T](a: openArray[T]): tuple[key: int, val: T] {.inline.} =
  ## iterates over each item of `a`. Yields ``(index, a[index])`` pairs.
  var i = 0
  while i < len(a):
    yield (i, a[i])
    inc(i)

iterator mpairs*[T](a: var openArray[T]): tuple[key:int, val:var T]{.inline.} =
  ## iterates over each item of `a`. Yields ``(index, a[index])`` pairs.
  ## ``a[index]`` can be modified.
  var i = 0
  while i < len(a):
    yield (i, a[i])
    inc(i)

iterator pairs*[IX, T](a: array[IX, T]): tuple[key: IX, val: T] {.inline.} =
  ## iterates over each item of `a`. Yields ``(index, a[index])`` pairs.
  var i = low(IX)
  if i <= high(IX):
    while true:
      yield (i, a[i])
      if i >= high(IX): break
      inc(i)

iterator mpairs*[IX, T](a:var array[IX, T]):tuple[key:IX,val:var T] {.inline.} =
  ## iterates over each item of `a`. Yields ``(index, a[index])`` pairs.
  ## ``a[index]`` can be modified.
  var i = low(IX)
  if i <= high(IX):
    while true:
      yield (i, a[i])
      if i >= high(IX): break
      inc(i)

iterator pairs*[T](a: seq[T]): tuple[key: int, val: T] {.inline.} =
  ## iterates over each item of `a`. Yields ``(index, a[index])`` pairs.
  var i = 0
  while i < len(a):
    yield (i, a[i])
    inc(i)

iterator mpairs*[T](a: var seq[T]): tuple[key: int, val: var T] {.inline.} =
  ## iterates over each item of `a`. Yields ``(index, a[index])`` pairs.
  ## ``a[index]`` can be modified.
  var i = 0
  while i < len(a):
    yield (i, a[i])
    inc(i)

iterator pairs*(a: string): tuple[key: int, val: char] {.inline.} =
  ## iterates over each item of `a`. Yields ``(index, a[index])`` pairs.
  var i = 0
  while i < len(a):
    yield (i, a[i])
    inc(i)

iterator mpairs*(a: var string): tuple[key: int, val: var char] {.inline.} =
  ## iterates over each item of `a`. Yields ``(index, a[index])`` pairs.
  ## ``a[index]`` can be modified.
  var i = 0
  while i < len(a):
    yield (i, a[i])
    inc(i)

iterator pairs*(a: cstring): tuple[key: int, val: char] {.inline.} =
  ## iterates over each item of `a`. Yields ``(index, a[index])`` pairs.
  var i = 0
  while a[i] != '\0':
    yield (i, a[i])
    inc(i)

iterator mpairs*(a: var cstring): tuple[key: int, val: var char] {.inline.} =
  ## iterates over each item of `a`. Yields ``(index, a[index])`` pairs.
  ## ``a[index]`` can be modified.
  var i = 0
  while a[i] != '\0':
    yield (i, a[i])
    inc(i)


proc isNil*[T](x: seq[T]): bool {.noSideEffect, magic: "IsNil".}
proc isNil*[T](x: ref T): bool {.noSideEffect, magic: "IsNil".}
proc isNil*(x: string): bool {.noSideEffect, magic: "IsNil".}
proc isNil*[T](x: ptr T): bool {.noSideEffect, magic: "IsNil".}
proc isNil*(x: pointer): bool {.noSideEffect, magic: "IsNil".}
proc isNil*(x: cstring): bool {.noSideEffect, magic: "IsNil".}
proc isNil*[T: proc](x: T): bool {.noSideEffect, magic: "IsNil".}
  ## Fast check whether `x` is nil. This is sometimes more efficient than
  ## ``== nil``.

proc `==` *[I, T](x, y: array[I, T]): bool =
  for f in low(x)..high(x):
    if x[f] != y[f]:
      return
  result = true

proc `@`*[T](a: openArray[T]): seq[T] =
  ## turns an openarray into a sequence. This is not as efficient as turning
  ## a fixed length array into a sequence as it always copies every element
  ## of `a`.
  newSeq(result, a.len)
  for i in 0..a.len-1: result[i] = a[i]

proc `&` *[T](x, y: seq[T]): seq[T] {.noSideEffect.} =
  ## Concatenates two sequences.
  ## Requires copying of the sequences.
  ##
  ## .. code-block:: Nim
  ##   assert(@[1, 2, 3, 4] & @[5, 6] == @[1, 2, 3, 4, 5, 6])
  newSeq(result, x.len + y.len)
  for i in 0..x.len-1:
    result[i] = x[i]
  for i in 0..y.len-1:
    result[i+x.len] = y[i]

proc `&` *[T](x: seq[T], y: T): seq[T] {.noSideEffect.} =
  ## Appends element y to the end of the sequence.
  ## Requires copying of the sequence
  ##
  ## .. code-block:: Nim
  ##   assert(@[1, 2, 3] & 4 == @[1, 2, 3, 4])
  newSeq(result, x.len + 1)
  for i in 0..x.len-1:
    result[i] = x[i]
  result[x.len] = y

proc `&` *[T](x: T, y: seq[T]): seq[T] {.noSideEffect.} =
  ## Prepends the element x to the beginning of the sequence.
  ## Requires copying of the sequence
  ##
  ## .. code-block:: Nim
  ##   assert(1 & @[2, 3, 4] == @[1, 2, 3, 4])
  newSeq(result, y.len + 1)
  result[0] = x
  for i in 0..y.len-1:
    result[i+1] = y[i]

when not defined(nimscript):
  when not defined(JS):
    proc seqToPtr[T](x: seq[T]): pointer {.inline, nosideeffect.} =
      result = cast[pointer](x)
  else:
    proc seqToPtr[T](x: seq[T]): pointer {.asmNoStackFrame, nosideeffect.} =
      asm """return `x`"""

  proc `==` *[T](x, y: seq[T]): bool {.noSideEffect.} =
    ## Generic equals operator for sequences: relies on a equals operator for
    ## the element type `T`.
    if seqToPtr(x) == seqToPtr(y):
      result = true
    elif seqToPtr(x) == nil or seqToPtr(y) == nil:
      result = false
    elif x.len == y.len:
      for i in 0..x.len-1:
        if x[i] != y[i]: return false
      result = true

proc find*[T, S](a: T, item: S): int {.inline.}=
  ## Returns the first index of `item` in `a` or -1 if not found. This requires
  ## appropriate `items` and `==` operations to work.
  for i in items(a):
    if i == item: return
    inc(result)
  result = -1

proc contains*[T](a: openArray[T], item: T): bool {.inline.}=
  ## Returns true if `item` is in `a` or false if not found. This is a shortcut
  ## for ``find(a, item) >= 0``.
  return find(a, item) >= 0

proc pop*[T](s: var seq[T]): T {.inline, noSideEffect.} =
  ## returns the last item of `s` and decreases ``s.len`` by one. This treats
  ## `s` as a stack and implements the common *pop* operation.
  var L = s.len-1
  result = s[L]
  setLen(s, L)

iterator fields*[T: tuple|object](x: T): RootObj {.
  magic: "Fields", noSideEffect.}
  ## iterates over every field of `x`. Warning: This really transforms
  ## the 'for' and unrolls the loop. The current implementation also has a bug
  ## that affects symbol binding in the loop body.
iterator fields*[S:tuple|object, T:tuple|object](x: S, y: T): tuple[a,b: expr] {.
  magic: "Fields", noSideEffect.}
  ## iterates over every field of `x` and `y`.
  ## Warning: This is really transforms the 'for' and unrolls the loop.
  ## The current implementation also has a bug that affects symbol binding
  ## in the loop body.
iterator fieldPairs*[T: tuple|object](x: T): RootObj {.
  magic: "FieldPairs", noSideEffect.}
  ## Iterates over every field of `x` returning their name and value.
  ##
  ## When you iterate over objects with different field types you have to use
  ## the compile time ``when`` instead of a runtime ``if`` to select the code
  ## you want to run for each type. To perform the comparison use the `is
  ## operator <manual.html#is-operator>`_. Example:
  ##
  ## .. code-block:: Nim
  ##
  ##   type
  ##     Custom = object
  ##       foo: string
  ##       bar: bool
  ##
  ##   proc `$`(x: Custom): string =
  ##     result = "Custom:"
  ##     for name, value in x.fieldPairs:
  ##       when value is bool:
  ##         result.add("\n\t" & name & " is " & $value)
  ##       else:
  ##         if value.isNil:
  ##           result.add("\n\t" & name & " (nil)")
  ##         else:
  ##           result.add("\n\t" & name & " '" & value & "'")
  ##
  ## Another way to do the same without ``when`` is to leave the task of
  ## picking the appropriate code to a secondary proc which you overload for
  ## each field type and pass the `value` to.
  ##
  ## Warning: This really transforms the 'for' and unrolls the loop. The
  ## current implementation also has a bug that affects symbol binding in the
  ## loop body.
iterator fieldPairs*[S: tuple|object, T: tuple|object](x: S, y: T): tuple[
  a, b: expr] {.
  magic: "FieldPairs", noSideEffect.}
  ## iterates over every field of `x` and `y`.
  ## Warning: This really transforms the 'for' and unrolls the loop.
  ## The current implementation also has a bug that affects symbol binding
  ## in the loop body.

proc `==`*[T: tuple|object](x, y: T): bool =
  ## generic ``==`` operator for tuples that is lifted from the components
  ## of `x` and `y`.
  for a, b in fields(x, y):
    if a != b: return false
  return true

proc `<=`*[T: tuple](x, y: T): bool =
  ## generic ``<=`` operator for tuples that is lifted from the components
  ## of `x` and `y`. This implementation uses `cmp`.
  for a, b in fields(x, y):
    var c = cmp(a, b)
    if c < 0: return true
    if c > 0: return false
  return true

proc `<`*[T: tuple](x, y: T): bool =
  ## generic ``<`` operator for tuples that is lifted from the components
  ## of `x` and `y`. This implementation uses `cmp`.
  for a, b in fields(x, y):
    var c = cmp(a, b)
    if c < 0: return true
    if c > 0: return false
  return false

proc `$`*[T: tuple|object](x: T): string =
  ## generic ``$`` operator for tuples that is lifted from the components
  ## of `x`. Example:
  ##
  ## .. code-block:: nim
  ##   $(23, 45) == "(23, 45)"
  ##   $() == "()"
  result = "("
  var firstElement = true
  for name, value in fieldPairs(x):
    if not firstElement: result.add(", ")
    result.add(name)
    result.add(": ")
    when compiles(value.isNil):
      if value.isNil: result.add "nil"
      else: result.add($value)
    else:
      result.add($value)
    firstElement = false
  result.add(")")

proc collectionToString[T: set | seq](x: T, b, e: string): string =
  when x is seq:
    if x.isNil: return "nil"
  result = b
  var firstElement = true
  for value in items(x):
    if not firstElement: result.add(", ")
    result.add($value)
    firstElement = false
  result.add(e)

proc `$`*[T](x: set[T]): string =
  ## generic ``$`` operator for sets that is lifted from the components
  ## of `x`. Example:
  ##
  ## .. code-block:: nim
  ##   ${23, 45} == "{23, 45}"
  collectionToString(x, "{", "}")

proc `$`*[T](x: seq[T]): string =
  ## generic ``$`` operator for seqs that is lifted from the components
  ## of `x`. Example:
  ##
  ## .. code-block:: nim
  ##   $(@[23, 45]) == "@[23, 45]"
  collectionToString(x, "@[", "]")

when false:
  # causes bootstrapping to fail as we use array of chars and cstring should
  # match better ...
  proc `$`*[T, IDX](x: array[IDX, T]): string =
    collectionToString(x, "[", "]")

# ----------------- GC interface ---------------------------------------------

when not defined(nimscript) and hasAlloc:
  proc GC_disable*() {.rtl, inl, benign.}
    ## disables the GC. If called n-times, n calls to `GC_enable` are needed to
    ## reactivate the GC. Note that in most circumstances one should only disable
    ## the mark and sweep phase with `GC_disableMarkAndSweep`.

  proc GC_enable*() {.rtl, inl, benign.}
    ## enables the GC again.

  proc GC_fullCollect*() {.rtl, benign.}
    ## forces a full garbage collection pass.
    ## Ordinary code does not need to call this (and should not).

  type
    GC_Strategy* = enum ## the strategy the GC should use for the application
      gcThroughput,      ## optimize for throughput
      gcResponsiveness,  ## optimize for responsiveness (default)
      gcOptimizeTime,    ## optimize for speed
      gcOptimizeSpace    ## optimize for memory footprint

  {.deprecated: [TGC_Strategy: GC_Strategy].}

  proc GC_setStrategy*(strategy: GC_Strategy) {.rtl, deprecated, benign.}
    ## tells the GC the desired strategy for the application.
    ## **Deprecated** since version 0.8.14. This has always been a nop.

  proc GC_enableMarkAndSweep*() {.rtl, benign.}
  proc GC_disableMarkAndSweep*() {.rtl, benign.}
    ## the current implementation uses a reference counting garbage collector
    ## with a seldomly run mark and sweep phase to free cycles. The mark and
    ## sweep phase may take a long time and is not needed if the application
    ## does not create cycles. Thus the mark and sweep phase can be deactivated
    ## and activated separately from the rest of the GC.

  proc GC_getStatistics*(): string {.rtl, benign.}
    ## returns an informative string about the GC's activity. This may be useful
    ## for tweaking.

  proc GC_ref*[T](x: ref T) {.magic: "GCref", benign.}
  proc GC_ref*[T](x: seq[T]) {.magic: "GCref", benign.}
  proc GC_ref*(x: string) {.magic: "GCref", benign.}
    ## marks the object `x` as referenced, so that it will not be freed until
    ## it is unmarked via `GC_unref`. If called n-times for the same object `x`,
    ## n calls to `GC_unref` are needed to unmark `x`.

  proc GC_unref*[T](x: ref T) {.magic: "GCunref", benign.}
  proc GC_unref*[T](x: seq[T]) {.magic: "GCunref", benign.}
  proc GC_unref*(x: string) {.magic: "GCunref", benign.}
    ## see the documentation of `GC_ref`.

template accumulateResult*(iter: expr) =
  ## helps to convert an iterator to a proc.
  result = @[]
  for x in iter: add(result, x)

# we have to compute this here before turning it off in except.nim anyway ...
const NimStackTrace = compileOption("stacktrace")

{.push checks: off.}
# obviously we cannot generate checking operations here :-)
# because it would yield into an endless recursion
# however, stack-traces are available for most parts
# of the code

var
  globalRaiseHook*: proc (e: ref Exception): bool {.nimcall, benign.}
    ## with this hook you can influence exception handling on a global level.
    ## If not nil, every 'raise' statement ends up calling this hook. Ordinary
    ## application code should never set this hook! You better know what you
    ## do when setting this. If ``globalRaiseHook`` returns false, the
    ## exception is caught and does not propagate further through the call
    ## stack.

  localRaiseHook* {.threadvar.}: proc (e: ref Exception): bool {.nimcall, benign.}
    ## with this hook you can influence exception handling on a
    ## thread local level.
    ## If not nil, every 'raise' statement ends up calling this hook. Ordinary
    ## application code should never set this hook! You better know what you
    ## do when setting this. If ``localRaiseHook`` returns false, the exception
    ## is caught and does not propagate further through the call stack.

  outOfMemHook*: proc () {.nimcall, tags: [], benign.}
    ## set this variable to provide a procedure that should be called
    ## in case of an `out of memory`:idx: event. The standard handler
    ## writes an error message and terminates the program. `outOfMemHook` can
    ## be used to raise an exception in case of OOM like so:
    ##
    ## .. code-block:: nim
    ##
    ##   var gOutOfMem: ref EOutOfMemory
    ##   new(gOutOfMem) # need to be allocated *before* OOM really happened!
    ##   gOutOfMem.msg = "out of memory"
    ##
    ##   proc handleOOM() =
    ##     raise gOutOfMem
    ##
    ##   system.outOfMemHook = handleOOM
    ##
    ## If the handler does not raise an exception, ordinary control flow
    ## continues and the program is terminated.

type
  PFrame* = ptr TFrame  ## represents a runtime frame of the call stack;
                        ## part of the debugger API.
  TFrame* {.importc, nodecl, final.} = object ## the frame itself
    prev*: PFrame       ## previous frame; used for chaining the call stack
    procname*: cstring  ## name of the proc that is currently executing
    line*: int          ## line number of the proc that is currently executing
    filename*: cstring  ## filename of the proc that is currently executing
    len*: int16         ## length of the inspectable slots
    calldepth*: int16   ## used for max call depth checking
#{.deprecated: [TFrame: Frame].}

when defined(JS):
  proc add*(x: var string, y: cstring) {.asmNoStackFrame.} =
    asm """
      var len = `x`[0].length-1;
      for (var i = 0; i < `y`.length; ++i) {
        `x`[0][len] = `y`.charCodeAt(i);
        ++len;
      }
      `x`[0][len] = 0
    """
  proc add*(x: var cstring, y: cstring) {.magic: "AppendStrStr".}

elif hasAlloc:
  {.push stack_trace:off, profiler:off.}
  proc add*(x: var string, y: cstring) =
    var i = 0
    while y[i] != '\0':
      add(x, y[i])
      inc(i)
  {.pop.}

when defined(nimvarargstyped):
  proc echo*(x: varargs[typed, `$`]) {.magic: "Echo", tags: [WriteIOEffect],
    benign, sideEffect.}
    ## Writes and flushes the parameters to the standard output.
    ##
    ## Special built-in that takes a variable number of arguments. Each argument
    ## is converted to a string via ``$``, so it works for user-defined
    ## types that have an overloaded ``$`` operator.
    ## It is roughly equivalent to ``writeLine(stdout, x); flushFile(stdout)``, but
    ## available for the JavaScript target too.
    ##
    ## Unlike other IO operations this is guaranteed to be thread-safe as
    ## ``echo`` is very often used for debugging convenience. If you want to use
    ## ``echo`` inside a `proc without side effects
    ## <manual.html#pragmas-nosideeffect-pragma>`_ you can use `debugEcho <#debugEcho>`_
    ## instead.

  proc debugEcho*(x: varargs[typed, `$`]) {.magic: "Echo", noSideEffect,
                                            tags: [], raises: [].}
    ## Same as `echo <#echo>`_, but as a special semantic rule, ``debugEcho``
    ## pretends to be free of side effects, so that it can be used for debugging
    ## routines marked as `noSideEffect <manual.html#pragmas-nosideeffect-pragma>`_.
else:
  proc echo*(x: varargs[expr, `$`]) {.magic: "Echo", tags: [WriteIOEffect],
    benign, sideEffect.}
  proc debugEcho*(x: varargs[expr, `$`]) {.magic: "Echo", noSideEffect,
                                             tags: [], raises: [].}

template newException*(exceptn: typedesc, message: string): expr =
  ## creates an exception object of type ``exceptn`` and sets its ``msg`` field
  ## to `message`. Returns the new exception object.
  var
    e: ref exceptn
  new(e)
  e.msg = message
  e

when hostOS == "standalone":
  include panicoverride

when not declared(sysFatal):
  when hostOS == "standalone":
    proc sysFatal(exceptn: typedesc, message: string) {.inline.} =
      panic(message)

    proc sysFatal(exceptn: typedesc, message, arg: string) {.inline.} =
      rawoutput(message)
      panic(arg)
  else:
    proc sysFatal(exceptn: typedesc, message: string) {.inline, noReturn.} =
      var e: ref exceptn
      new(e)
      e.msg = message
      raise e

    proc sysFatal(exceptn: typedesc, message, arg: string) {.inline, noReturn.} =
      var e: ref exceptn
      new(e)
      e.msg = message & arg
      raise e

proc getTypeInfo*[T](x: T): pointer {.magic: "GetTypeInfo", benign.}
  ## get type information for `x`. Ordinary code should not use this, but
  ## the `typeinfo` module instead.

{.push stackTrace: off.}
proc abs*(x: int): int {.magic: "AbsI", noSideEffect.} =
  if x < 0: -x else: x
proc abs*(x: int8): int8 {.magic: "AbsI", noSideEffect.} =
  if x < 0: -x else: x
proc abs*(x: int16): int16 {.magic: "AbsI", noSideEffect.} =
  if x < 0: -x else: x
proc abs*(x: int32): int32 {.magic: "AbsI", noSideEffect.} =
  if x < 0: -x else: x
when defined(nimnomagic64):
  proc abs*(x: int64): int64 {.magic: "AbsI", noSideEffect.} =
    ## returns the absolute value of `x`. If `x` is ``low(x)`` (that
    ## is -MININT for its type), an overflow exception is thrown (if overflow
    ## checking is turned on).
    if x < 0: -x else: x
else:
  proc abs*(x: int64): int64 {.magic: "AbsI64", noSideEffect.} =
    ## returns the absolute value of `x`. If `x` is ``low(x)`` (that
    ## is -MININT for its type), an overflow exception is thrown (if overflow
    ## checking is turned on).
    if x < 0: -x else: x
{.pop.}

when not defined(JS): #and not defined(nimscript):
  {.push stack_trace: off, profiler:off.}

  when not defined(nimscript) and not defined(nogc):
    proc initGC()
    when not defined(boehmgc) and not defined(useMalloc) and not defined(gogc):
      proc initAllocator() {.inline.}

    proc initStackBottom() {.inline, compilerproc.} =
      # WARNING: This is very fragile! An array size of 8 does not work on my
      # Linux 64bit system. -- That's because the stack direction is the other
      # way round.
      when declared(setStackBottom):
        var locals {.volatile.}: pointer
        locals = addr(locals)
        setStackBottom(locals)

    proc initStackBottomWith(locals: pointer) {.inline, compilerproc.} =
      # We need to keep initStackBottom around for now to avoid
      # bootstrapping problems.
      when declared(setStackBottom):
        setStackBottom(locals)

  when hasAlloc:
    var
      strDesc: TNimType

    strDesc.size = sizeof(string)
    strDesc.kind = tyString
    strDesc.flags = {ntfAcyclic}

  when not defined(nimscript):
    include "system/ansi_c"

    proc cmp(x, y: string): int =
      result = int(c_strcmp(x, y))
  else:
    proc cmp(x, y: string): int =
      if x < y: result = -1
      elif x > y: result = 1
      else: result = 0

  const pccHack = if defined(pcc): "_" else: "" # Hack for PCC
  when not defined(nimscript):
    when defined(windows):
      # work-around C's sucking abstraction:
      # BUGFIX: stdin and stdout should be binary files!
      proc setmode(handle, mode: int) {.importc: pccHack & "setmode",
                                        header: "<io.h>".}
      proc fileno(f: C_TextFileStar): int {.importc: pccHack & "fileno",
                                            header: "<fcntl.h>".}
      var
        O_BINARY {.importc: pccHack & "O_BINARY", nodecl.}: int

      # we use binary mode in Windows:
      setmode(fileno(c_stdin), O_BINARY)
      setmode(fileno(c_stdout), O_BINARY)

    when defined(endb):
      proc endbStep()

  # ----------------- IO Part ------------------------------------------------
  when hostOS != "standalone":
    type
      CFile {.importc: "FILE", header: "<stdio.h>",
              final, incompletestruct.} = object
      File* = ptr CFile ## The type representing a file handle.

      FileMode* = enum           ## The file mode when opening a file.
        fmRead,                   ## Open the file for read access only.
        fmWrite,                  ## Open the file for write access only.
        fmReadWrite,              ## Open the file for read and write access.
                                  ## If the file does not exist, it will be
                                  ## created.
        fmReadWriteExisting,      ## Open the file for read and write access.
                                  ## If the file does not exist, it will not be
                                  ## created.
        fmAppend                  ## Open the file for writing only; append data
                                  ## at the end.

      FileHandle* = cint ## type that represents an OS file handle; this is
                         ## useful for low-level file access

    {.deprecated: [TFile: File, TFileHandle: FileHandle, TFileMode: FileMode].}

    when not defined(nimscript):
      # text file handling:
      var
        stdin* {.importc: "stdin", header: "<stdio.h>".}: File
          ## The standard input stream.
        stdout* {.importc: "stdout", header: "<stdio.h>".}: File
          ## The standard output stream.
        stderr* {.importc: "stderr", header: "<stdio.h>".}: File
          ## The standard error stream.

    when defined(useStdoutAsStdmsg):
      template stdmsg*: File = stdout
    else:
      template stdmsg*: File = stderr
        ## Template which expands to either stdout or stderr depending on
        ## `useStdoutAsStdmsg` compile-time switch.

    proc open*(f: var File, filename: string,
               mode: FileMode = fmRead, bufSize: int = -1): bool {.tags: [],
               benign.}
      ## Opens a file named `filename` with given `mode`.
      ##
      ## Default mode is readonly. Returns true iff the file could be opened.
      ## This throws no exception if the file could not be opened.

    proc open*(f: var File, filehandle: FileHandle,
               mode: FileMode = fmRead): bool {.tags: [], benign.}
      ## Creates a ``File`` from a `filehandle` with given `mode`.
      ##
      ## Default mode is readonly. Returns true iff the file could be opened.

    proc open*(filename: string,
               mode: FileMode = fmRead, bufSize: int = -1): File =
      ## Opens a file named `filename` with given `mode`.
      ##
      ## Default mode is readonly. Raises an ``IO`` exception if the file
      ## could not be opened.
      if not open(result, filename, mode, bufSize):
        sysFatal(IOError, "cannot open: ", filename)

    proc reopen*(f: File, filename: string, mode: FileMode = fmRead): bool {.
      tags: [], benign.}
      ## reopens the file `f` with given `filename` and `mode`. This
      ## is often used to redirect the `stdin`, `stdout` or `stderr`
      ## file variables.
      ##
      ## Default mode is readonly. Returns true iff the file could be reopened.

    proc close*(f: File) {.importc: "fclose", header: "<stdio.h>", tags: [].}
      ## Closes the file.

    proc endOfFile*(f: File): bool {.tags: [], benign.}
      ## Returns true iff `f` is at the end.

    proc readChar*(f: File): char {.
      importc: "fgetc", header: "<stdio.h>", tags: [ReadIOEffect].}
      ## Reads a single character from the stream `f`.
    proc flushFile*(f: File) {.
      importc: "fflush", header: "<stdio.h>", tags: [WriteIOEffect].}
      ## Flushes `f`'s buffer.

    proc readAll*(file: File): TaintedString {.tags: [ReadIOEffect], benign.}
      ## Reads all data from the stream `file`.
      ##
      ## Raises an IO exception in case of an error. It is an error if the
      ## current file position is not at the beginning of the file.

    proc readFile*(filename: string): TaintedString {.tags: [ReadIOEffect], benign.}
      ## Opens a file named `filename` for reading.
      ##
      ## Then calls `readAll <#readAll>`_ and closes the file afterwards.
      ## Returns the string.  Raises an IO exception in case of an error. If
      ## you need to call this inside a compile time macro you can use
      ## `staticRead <#staticRead>`_.

    proc writeFile*(filename, content: string) {.tags: [WriteIOEffect], benign.}
      ## Opens a file named `filename` for writing. Then writes the
      ## `content` completely to the file and closes the file afterwards.
      ## Raises an IO exception in case of an error.

    proc write*(f: File, r: float32) {.tags: [WriteIOEffect], benign.}
    proc write*(f: File, i: int) {.tags: [WriteIOEffect], benign.}
    proc write*(f: File, i: BiggestInt) {.tags: [WriteIOEffect], benign.}
    proc write*(f: File, r: BiggestFloat) {.tags: [WriteIOEffect], benign.}
    proc write*(f: File, s: string) {.tags: [WriteIOEffect], benign.}
    proc write*(f: File, b: bool) {.tags: [WriteIOEffect], benign.}
    proc write*(f: File, c: char) {.tags: [WriteIOEffect], benign.}
    proc write*(f: File, c: cstring) {.tags: [WriteIOEffect], benign.}
    proc write*(f: File, a: varargs[string, `$`]) {.tags: [WriteIOEffect], benign.}
      ## Writes a value to the file `f`. May throw an IO exception.

    proc readLine*(f: File): TaintedString  {.tags: [ReadIOEffect], benign.}
      ## reads a line of text from the file `f`. May throw an IO exception.
      ## A line of text may be delimited by ``LF`` or ``CRLF``. The newline
      ## character(s) are not part of the returned string.

    proc readLine*(f: File, line: var TaintedString): bool {.tags: [ReadIOEffect],
                  benign.}
      ## reads a line of text from the file `f` into `line`. `line` must not be
      ## ``nil``! May throw an IO exception.
      ## A line of text may be delimited by ``LF`` or ``CRLF``. The newline
      ## character(s) are not part of the returned string. Returns ``false``
      ## if the end of the file has been reached, ``true`` otherwise. If
      ## ``false`` is returned `line` contains no new data.

    proc writeLn*[Ty](f: File, x: varargs[Ty, `$`]) {.inline,
                             tags: [WriteIOEffect], benign, deprecated.}
      ## **Deprecated since version 0.11.4:** Use **writeLine** instead.

    proc writeLine*[Ty](f: File, x: varargs[Ty, `$`]) {.inline,
                             tags: [WriteIOEffect], benign.}
      ## writes the values `x` to `f` and then writes "\n".
      ## May throw an IO exception.

    proc getFileSize*(f: File): int64 {.tags: [ReadIOEffect], benign.}
      ## retrieves the file size (in bytes) of `f`.

    proc readBytes*(f: File, a: var openArray[int8|uint8], start, len: Natural): int {.
      tags: [ReadIOEffect], benign.}
      ## reads `len` bytes into the buffer `a` starting at ``a[start]``. Returns
      ## the actual number of bytes that have been read which may be less than
      ## `len` (if not as many bytes are remaining), but not greater.

    proc readChars*(f: File, a: var openArray[char], start, len: Natural): int {.
      tags: [ReadIOEffect], benign.}
      ## reads `len` bytes into the buffer `a` starting at ``a[start]``. Returns
      ## the actual number of bytes that have been read which may be less than
      ## `len` (if not as many bytes are remaining), but not greater.

    proc readBuffer*(f: File, buffer: pointer, len: Natural): int {.
      tags: [ReadIOEffect], benign.}
      ## reads `len` bytes into the buffer pointed to by `buffer`. Returns
      ## the actual number of bytes that have been read which may be less than
      ## `len` (if not as many bytes are remaining), but not greater.

    proc writeBytes*(f: File, a: openArray[int8|uint8], start, len: Natural): int {.
      tags: [WriteIOEffect], benign.}
      ## writes the bytes of ``a[start..start+len-1]`` to the file `f`. Returns
      ## the number of actual written bytes, which may be less than `len` in case
      ## of an error.

    proc writeChars*(f: File, a: openArray[char], start, len: Natural): int {.
      tags: [WriteIOEffect], benign.}
      ## writes the bytes of ``a[start..start+len-1]`` to the file `f`. Returns
      ## the number of actual written bytes, which may be less than `len` in case
      ## of an error.

    proc writeBuffer*(f: File, buffer: pointer, len: Natural): int {.
      tags: [WriteIOEffect], benign.}
      ## writes the bytes of buffer pointed to by the parameter `buffer` to the
      ## file `f`. Returns the number of actual written bytes, which may be less
      ## than `len` in case of an error.

    proc setFilePos*(f: File, pos: int64) {.benign.}
      ## sets the position of the file pointer that is used for read/write
      ## operations. The file's first byte has the index zero.

    proc getFilePos*(f: File): int64 {.benign.}
      ## retrieves the current position of the file pointer that is used to
      ## read from the file `f`. The file's first byte has the index zero.

    proc getFileHandle*(f: File): FileHandle {.importc: "fileno",
                                               header: "<stdio.h>"}
      ## returns the OS file handle of the file ``f``. This is only useful for
      ## platform specific programming.

    when not defined(nimfix):
      {.deprecated: [fileHandle: getFileHandle].}

  when declared(newSeq):
    proc cstringArrayToSeq*(a: cstringArray, len: Natural): seq[string] =
      ## converts a ``cstringArray`` to a ``seq[string]``. `a` is supposed to be
      ## of length ``len``.
      newSeq(result, len)
      for i in 0..len-1: result[i] = $a[i]

    proc cstringArrayToSeq*(a: cstringArray): seq[string] =
      ## converts a ``cstringArray`` to a ``seq[string]``. `a` is supposed to be
      ## terminated by ``nil``.
      var L = 0
      while a[L] != nil: inc(L)
      result = cstringArrayToSeq(a, L)

  # -------------------------------------------------------------------------

  when declared(alloc0) and declared(dealloc):
    proc allocCStringArray*(a: openArray[string]): cstringArray =
      ## creates a NULL terminated cstringArray from `a`. The result has to
      ## be freed with `deallocCStringArray` after it's not needed anymore.
      result = cast[cstringArray](alloc0((a.len+1) * sizeof(cstring)))
      let x = cast[ptr array[0..ArrayDummySize, string]](a)
      for i in 0 .. a.high:
        result[i] = cast[cstring](alloc0(x[i].len+1))
        copyMem(result[i], addr(x[i][0]), x[i].len)

    proc deallocCStringArray*(a: cstringArray) =
      ## frees a NULL terminated cstringArray.
      var i = 0
      while a[i] != nil:
        dealloc(a[i])
        inc(i)
      dealloc(a)

  when not defined(nimscript):
    proc atomicInc*(memLoc: var int, x: int = 1): int {.inline,
      discardable, benign.}
      ## atomic increment of `memLoc`. Returns the value after the operation.

    proc atomicDec*(memLoc: var int, x: int = 1): int {.inline,
      discardable, benign.}
      ## atomic decrement of `memLoc`. Returns the value after the operation.

    include "system/atomics"

    type
      PSafePoint = ptr TSafePoint
      TSafePoint {.compilerproc, final.} = object
        prev: PSafePoint # points to next safe point ON THE STACK
        status: int
        context: C_JmpBuf
        hasRaiseAction: bool
        raiseAction: proc (e: ref Exception): bool {.closure.}
      SafePoint = TSafePoint
  #  {.deprecated: [TSafePoint: SafePoint].}

  when declared(initAllocator):
    initAllocator()
  when hasThreadSupport:
    include "system/syslocks"
    when hostOS != "standalone": include "system/threads"
  elif not defined(nogc) and not defined(nimscript):
    when not defined(useNimRtl) and not defined(createNimRtl): initStackBottom()
    when declared(initGC): initGC()

  when not defined(nimscript):
    proc setControlCHook*(hook: proc () {.noconv.} not nil)
      ## allows you to override the behaviour of your application when CTRL+C
      ## is pressed. Only one such hook is supported.

    proc writeStackTrace*() {.tags: [WriteIOEffect].}
      ## writes the current stack trace to ``stderr``. This is only works
      ## for debug builds.
    when hostOS != "standalone":
      proc getStackTrace*(): string
        ## gets the current stack trace. This only works for debug builds.

      proc getStackTrace*(e: ref Exception): string
        ## gets the stack trace associated with `e`, which is the stack that
        ## lead to the ``raise`` statement. This only works for debug builds.

    {.push stack_trace: off, profiler:off.}
    when hostOS == "standalone":
      include "system/embedded"
    else:
      include "system/excpt"
    include "system/chcks"

    # we cannot compile this with stack tracing on
    # as it would recurse endlessly!
    include "system/arithm"
    {.pop.} # stack trace
  {.pop.} # stack trace

  when hostOS != "standalone" and not defined(nimscript):
    include "system/dyncalls"
  when not defined(nimscript):
    include "system/sets"

    when defined(gogc):
      const GenericSeqSize = (3 * sizeof(int))
    else:
      const GenericSeqSize = (2 * sizeof(int))

    proc getDiscriminant(aa: pointer, n: ptr TNimNode): int =
      sysAssert(n.kind == nkCase, "getDiscriminant: node != nkCase")
      var d: int
      var a = cast[ByteAddress](aa)
      case n.typ.size
      of 1: d = ze(cast[ptr int8](a +% n.offset)[])
      of 2: d = ze(cast[ptr int16](a +% n.offset)[])
      of 4: d = int(cast[ptr int32](a +% n.offset)[])
      else: sysAssert(false, "getDiscriminant: invalid n.typ.size")
      return d

    proc selectBranch(aa: pointer, n: ptr TNimNode): ptr TNimNode =
      var discr = getDiscriminant(aa, n)
      if discr <% n.len:
        result = n.sons[discr]
        if result == nil: result = n.sons[n.len]
        # n.sons[n.len] contains the ``else`` part (but may be nil)
      else:
        result = n.sons[n.len]

    when hasAlloc: include "system/mmdisp"
    {.push stack_trace: off, profiler:off.}
    when hasAlloc: include "system/sysstr"
    {.pop.}

    when hostOS != "standalone": include "system/sysio"
    when hasThreadSupport:
      when hostOS != "standalone": include "system/channels"
  else:
    include "system/sysio"

  when declared(open) and declared(close) and declared(readline):
    iterator lines*(filename: string): TaintedString {.tags: [ReadIOEffect].} =
      ## Iterates over any line in the file named `filename`.
      ##
      ## If the file does not exist `EIO` is raised. The trailing newline
      ## character(s) are removed from the iterated lines. Example:
      ##
      ## .. code-block:: nim
      ##   import strutils
      ##
      ##   proc transformLetters(filename: string) =
      ##     var buffer = ""
      ##     for line in filename.lines:
      ##       buffer.add(line.replace("a", "0") & '\x0A')
      ##     writeFile(filename, buffer)
      var f = open(filename, bufSize=8000)
      var res = TaintedString(newStringOfCap(80))
      while f.readLine(res): yield res
      close(f)

    iterator lines*(f: File): TaintedString {.tags: [ReadIOEffect].} =
      ## Iterate over any line in the file `f`.
      ##
      ## The trailing newline character(s) are removed from the iterated lines.
      ## Example:
      ##
      ## .. code-block:: nim
      ##   proc countZeros(filename: File): tuple[lines, zeros: int] =
      ##     for line in filename.lines:
      ##       for letter in line:
      ##         if letter == '0':
      ##           result.zeros += 1
      ##       result.lines += 1
      var res = TaintedString(newStringOfCap(80))
      while f.readLine(res): yield res

  when not defined(nimscript) and hasAlloc:
    include "system/assign"
    include "system/repr"

  when hostOS != "standalone" and not defined(nimscript):
    proc getCurrentException*(): ref Exception {.compilerRtl, inl, benign.} =
      ## retrieves the current exception; if there is none, nil is returned.
      result = currException

    proc getCurrentExceptionMsg*(): string {.inline, benign.} =
      ## retrieves the error message that was attached to the current
      ## exception; if there is none, "" is returned.
      var e = getCurrentException()
      return if e == nil: "" else: e.msg

    proc onRaise*(action: proc(e: ref Exception): bool{.closure.}) =
      ## can be used in a ``try`` statement to setup a Lisp-like
      ## `condition system`:idx:\: This prevents the 'raise' statement to
      ## raise an exception but instead calls ``action``.
      ## If ``action`` returns false, the exception has been handled and
      ## does not propagate further through the call stack.
      if not isNil(excHandler):
        excHandler.hasRaiseAction = true
        excHandler.raiseAction = action

    proc setCurrentException*(exc: ref Exception) {.inline, benign.} =
      ## sets the current exception.
      ##
      ## **Warning**: Only use this if you know what you are doing.
      currException = exc

  {.push stack_trace: off, profiler:off.}
  when defined(endb) and not defined(nimscript):
    include "system/debugger"

  when defined(profiler) or defined(memProfiler):
    include "system/profiler"
  {.pop.} # stacktrace

  when not defined(nimscript):
    proc likely*(val: bool): bool {.importc: "likely", nodecl, nosideeffect.}
      ## Hints the optimizer that `val` is likely going to be true.
      ##
      ## You can use this proc to decorate a branch condition. On certain
      ## platforms this can help the processor predict better which branch is
      ## going to be run. Example:
      ##
      ## .. code-block:: nim
      ##   for value in inputValues:
      ##     if likely(value <= 100):
      ##       process(value)
      ##     else:
      ##       echo "Value too big!"

    proc unlikely*(val: bool): bool {.importc: "unlikely", nodecl, nosideeffect.}
      ## Hints the optimizer that `val` is likely going to be false.
      ##
      ## You can use this proc to decorate a branch condition. On certain
      ## platforms this can help the processor predict better which branch is
      ## going to be run. Example:
      ##
      ## .. code-block:: nim
      ##   for value in inputValues:
      ##     if unlikely(value > 100):
      ##       echo "Value too big!"
      ##     else:
      ##       process(value)

    proc rawProc*[T: proc](x: T): pointer {.noSideEffect, inline.} =
      ## retrieves the raw proc pointer of the closure `x`. This is
      ## useful for interfacing closures with C.
      {.emit: """
      `result` = `x`.ClPrc;
      """.}

    proc rawEnv*[T: proc](x: T): pointer {.noSideEffect, inline.} =
      ## retrieves the raw environment pointer of the closure `x`. This is
      ## useful for interfacing closures with C.
      {.emit: """
      `result` = `x`.ClEnv;
      """.}

    proc finished*[T: proc](x: T): bool {.noSideEffect, inline.} =
      ## can be used to determine if a first class iterator has finished.
      {.emit: """
      `result` = *((NI*) `x`.ClEnv) < 0;
      """.}

elif defined(JS):
  # Stubs:
  proc nimGCvisit(d: pointer, op: int) {.compilerRtl.} = discard

  proc GC_disable() = discard
  proc GC_enable() = discard
  proc GC_fullCollect() = discard
  proc GC_setStrategy(strategy: GC_Strategy) = discard
  proc GC_enableMarkAndSweep() = discard
  proc GC_disableMarkAndSweep() = discard
  proc GC_getStatistics(): string = return ""

  proc getOccupiedMem(): int = return -1
  proc getFreeMem(): int = return -1
  proc getTotalMem(): int = return -1

  proc dealloc(p: pointer) = discard
  proc alloc(size: Natural): pointer = discard
  proc alloc0(size: Natural): pointer = discard
  proc realloc(p: pointer, newsize: Natural): pointer = discard

  proc allocShared(size: Natural): pointer = discard
  proc allocShared0(size: Natural): pointer = discard
  proc deallocShared(p: pointer) = discard
  proc reallocShared(p: pointer, newsize: Natural): pointer = discard

  when defined(JS):
    include "system/jssys"
    include "system/reprjs"
  elif defined(nimscript):
    proc cmp(x, y: string): int =
      if x == y: return 0
      if x < y: return -1
      return 1

  when defined(nimffi):
    include "system/sysio"


proc quit*(errormsg: string, errorcode = QuitFailure) {.noReturn.} =
  ## a shorthand for ``echo(errormsg); quit(errorcode)``.
  echo(errormsg)
  quit(errorcode)

{.pop.} # checks
{.pop.} # hints

proc `/`*(x, y: int): float {.inline, noSideEffect.} =
  ## integer division that results in a float.
  result = toFloat(x) / toFloat(y)

template spliceImpl(s, a, L, b: expr): stmt {.immediate.} =
  # make room for additional elements or cut:
  var slen = s.len
  var shift = b.len - L
  var newLen = slen + shift
  if shift > 0:
    # enlarge:
    setLen(s, newLen)
    for i in countdown(newLen-1, a+shift+1): shallowCopy(s[i], s[i-shift])
  else:
    for i in countup(a+b.len, s.len-1+shift): shallowCopy(s[i], s[i-shift])
    # cut down:
    setLen(s, newLen)
  # fill the hole:
  for i in 0 .. <b.len: s[i+a] = b[i]

when hasAlloc or defined(nimscript):
  proc `[]`*(s: string, x: Slice[int]): string {.inline.} =
    ## slice operation for strings.
    result = s.substr(x.a, x.b)

  proc `[]=`*(s: var string, x: Slice[int], b: string) =
    ## slice assignment for strings. If
    ## ``b.len`` is not exactly the number of elements that are referred to
    ## by `x`, a `splice`:idx: is performed:
    ##
    ## .. code-block:: nim
    ##   var s = "abcdef"
    ##   s[1 .. ^2] = "xyz"
    ##   assert s == "axyzf"
    var a = x.a
    var L = x.b - a + 1
    if L == b.len:
      for i in 0 .. <L: s[i+a] = b[i]
    else:
      spliceImpl(s, a, L, b)

proc `[]`*[Idx, T](a: array[Idx, T], x: Slice[int]): seq[T] =
  ## slice operation for arrays.
  when low(a) < 0:
    {.error: "Slicing for arrays with negative indices is unsupported.".}
  var L = x.b - x.a + 1
  newSeq(result, L)
  for i in 0.. <L: result[i] = a[i + x.a]

proc `[]=`*[Idx, T](a: var array[Idx, T], x: Slice[int], b: openArray[T]) =
  ## slice assignment for arrays.
  when low(a) < 0:
    {.error: "Slicing for arrays with negative indices is unsupported.".}
  var L = x.b - x.a + 1
  if L == b.len:
    for i in 0 .. <L: a[i+x.a] = b[i]
  else:
    sysFatal(RangeError, "different lengths for slice assignment")

proc `[]`*[Idx, T](a: array[Idx, T], x: Slice[Idx]): seq[T] =
  ## slice operation for arrays.
  var L = ord(x.b) - ord(x.a) + 1
  newSeq(result, L)
  for i in 0.. <L:
    result[i] = a[Idx(ord(x.a) + i)]

proc `[]=`*[Idx, T](a: var array[Idx, T], x: Slice[Idx], b: openArray[T]) =
  ## slice assignment for arrays.
  var L = ord(x.b) - ord(x.a) + 1
  if L == b.len:
    for i in 0 .. <L:
      a[Idx(ord(x.a) + i)] = b[i]
  else:
    sysFatal(RangeError, "different lengths for slice assignment")

proc `[]`*[T](s: seq[T], x: Slice[int]): seq[T] =
  ## slice operation for sequences.
  var a = x.a
  var L = x.b - a + 1
  newSeq(result, L)
  for i in 0.. <L: result[i] = s[i + a]

proc `[]=`*[T](s: var seq[T], x: Slice[int], b: openArray[T]) =
  ## slice assignment for sequences. If
  ## ``b.len`` is not exactly the number of elements that are referred to
  ## by `x`, a `splice`:idx: is performed.
  var a = x.a
  var L = x.b - a + 1
  if L == b.len:
    for i in 0 .. <L: s[i+a] = b[i]
  else:
    spliceImpl(s, a, L, b)

proc slurp*(filename: string): string {.magic: "Slurp".}
  ## This is an alias for `staticRead <#staticRead>`_.

proc staticRead*(filename: string): string {.magic: "Slurp".}
  ## Compile-time `readFile <#readFile>`_ proc for easy `resource`:idx:
  ## embedding:
  ##
  ## .. code-block:: nim
  ##     const myResource = staticRead"mydatafile.bin"
  ##
  ## `slurp <#slurp>`_ is an alias for ``staticRead``.

proc gorge*(command: string, input = "", cache = ""): string {.
  magic: "StaticExec".} = discard
  ## This is an alias for `staticExec <#staticExec>`_.

proc staticExec*(command: string, input = "", cache = ""): string {.
  magic: "StaticExec".} = discard
  ## Executes an external process at compile-time.
  ## if `input` is not an empty string, it will be passed as a standard input
  ## to the executed program.
  ##
  ## .. code-block:: nim
  ##     const buildInfo = "Revision " & staticExec("git rev-parse HEAD") &
  ##                       "\nCompiled on " & staticExec("uname -v")
  ##
  ## `gorge <#gorge>`_ is an alias for ``staticExec``. Note that you can use
  ## this proc inside a pragma like `passC <nimc.html#passc-pragma>`_ or `passL
  ## <nimc.html#passl-pragma>`_.
  ##
  ## If ``cache`` is not empty, the results of ``staticExec`` are cached within
  ## the ``nimcache`` directory. Use ``--forceBuild`` to get rid of this caching
  ## behaviour then. ``command & input & cache`` (the concatenated string) is
  ## used to determine wether the entry in the cache is still valid. You can
  ## use versioning information for ``cache``:
  ##
  ## .. code-block:: nim
  ##     const stateMachine = staticExec("dfaoptimizer", "input", "0.8.0")

proc `+=`*[T: SomeOrdinal|uint|uint64](x: var T, y: T) {.
  magic: "Inc", noSideEffect.}
  ## Increments an ordinal

proc `-=`*[T: SomeOrdinal|uint|uint64](x: var T, y: T) {.
  magic: "Dec", noSideEffect.}
  ## Decrements an ordinal

proc `*=`*[T: SomeOrdinal|uint|uint64](x: var T, y: T) {.
  inline, noSideEffect.} =
  ## Binary `*=` operator for ordinals
  x = x * y

proc `+=`*[T: float|float32|float64] (x: var T, y: T) {.
  inline, noSideEffect.} =
  ## Increments in placee a floating point number
  x = x + y

proc `-=`*[T: float|float32|float64] (x: var T, y: T) {.
  inline, noSideEffect.} =
  ## Decrements in place a floating point number
  x = x - y

proc `*=`*[T: float|float32|float64] (x: var T, y: T) {.
  inline, noSideEffect.} =
  ## Multiplies in place a floating point number
  x = x * y

proc `/=`*(x: var float64, y: float64) {.inline, noSideEffect.} =
  ## Divides in place a floating point number
  x = x / y

proc `/=`*[T: float|float32](x: var T, y: T) {.inline, noSideEffect.} =
  ## Divides in place a floating point number
  x = x / y

proc `&=`* (x: var string, y: string) {.magic: "AppendStrStr", noSideEffect.}

proc astToStr*[T](x: T): string {.magic: "AstToStr", noSideEffect.}
  ## converts the AST of `x` into a string representation. This is very useful
  ## for debugging.

proc instantiationInfo*(index = -1, fullPaths = false): tuple[
  filename: string, line: int] {. magic: "InstantiationInfo", noSideEffect.}
  ## provides access to the compiler's instantiation stack line information.
  ##
  ## This proc is mostly useful for meta programming (eg. ``assert`` template)
  ## to retrieve information about the current filename and line number.
  ## Example:
  ##
  ## .. code-block:: nim
  ##   import strutils
  ##
  ##   template testException(exception, code: expr): stmt =
  ##     try:
  ##       let pos = instantiationInfo()
  ##       discard(code)
  ##       echo "Test failure at $1:$2 with '$3'" % [pos.filename,
  ##         $pos.line, astToStr(code)]
  ##       assert false, "A test expecting failure succeeded?"
  ##     except exception:
  ##       discard
  ##
  ##   proc tester(pos: int): int =
  ##     let
  ##       a = @[1, 2, 3]
  ##     result = a[pos]
  ##
  ##   when isMainModule:
  ##     testException(IndexError, tester(30))
  ##     testException(IndexError, tester(1))
  ##     # --> Test failure at example.nim:20 with 'tester(1)'

template currentSourcePath*: string = instantiationInfo(-1, true).filename
  ## returns the full file-system path of the current source

proc raiseAssert*(msg: string) {.noinline.} =
  sysFatal(AssertionError, msg)

proc failedAssertImpl*(msg: string) {.raises: [], tags: [].} =
  # trick the compiler to not list ``AssertionError`` when called
  # by ``assert``.
  type Hide = proc (msg: string) {.noinline, raises: [], noSideEffect,
                                    tags: [].}
  {.deprecated: [THide: Hide].}
  Hide(raiseAssert)(msg)

template assert*(cond: bool, msg = "") =
  ## Raises ``AssertionError`` with `msg` if `cond` is false. Note
  ## that ``AssertionError`` is hidden from the effect system, so it doesn't
  ## produce ``{.raises: [AssertionError].}``. This exception is only supposed
  ## to be caught by unit testing frameworks.
  ## The compiler may not generate any code at all for ``assert`` if it is
  ## advised to do so through the ``-d:release`` or ``--assertions:off``
  ## `command line switches <nimc.html#command-line-switches>`_.
  bind instantiationInfo
  mixin failedAssertImpl
  when compileOption("assertions"):
    {.line.}:
      if not cond: failedAssertImpl(astToStr(cond) & ' ' & msg)

template doAssert*(cond: bool, msg = "") =
  ## same as `assert` but is always turned on and not affected by the
  ## ``--assertions`` command line switch.
  bind instantiationInfo
  {.line: instantiationInfo().}:
    if not cond:
      raiseAssert(astToStr(cond) & ' ' & msg)

iterator items*[T](a: seq[T]): T {.inline.} =
  ## iterates over each item of `a`.
  var i = 0
  let L = len(a)
  while i < L:
    yield a[i]
    inc(i)
    assert(len(a) == L, "seq modified while iterating over it")

iterator mitems*[T](a: var seq[T]): var T {.inline.} =
  ## iterates over each item of `a` so that you can modify the yielded value.
  var i = 0
  let L = len(a)
  while i < L:
    yield a[i]
    inc(i)
    assert(len(a) == L, "seq modified while iterating over it")

iterator items*(a: string): char {.inline.} =
  ## iterates over each item of `a`.
  var i = 0
  let L = len(a)
  while i < L:
    yield a[i]
    inc(i)
    assert(len(a) == L, "string modified while iterating over it")

iterator mitems*(a: var string): var char {.inline.} =
  ## iterates over each item of `a` so that you can modify the yielded value.
  var i = 0
  let L = len(a)
  while i < L:
    yield a[i]
    inc(i)
    assert(len(a) == L, "string modified while iterating over it")

when not defined(nimhygiene):
  {.pragma: inject.}

template onFailedAssert*(msg: expr, code: stmt): stmt {.dirty, immediate.} =
  ## Sets an assertion failure handler that will intercept any assert
  ## statements following `onFailedAssert` in the current module scope.
  ##
  ## .. code-block:: nim
  ##  # module-wide policy to change the failed assert
  ##  # exception type in order to include a lineinfo
  ##  onFailedAssert(msg):
  ##    var e = new(TMyError)
  ##    e.msg = msg
  ##    e.lineinfo = instantiationInfo(-2)
  ##    raise e
  ##
  template failedAssertImpl(msgIMPL: string): stmt {.dirty.} =
    let msg = msgIMPL
    code

proc shallow*[T](s: var seq[T]) {.noSideEffect, inline.} =
  ## marks a sequence `s` as `shallow`:idx:. Subsequent assignments will not
  ## perform deep copies of `s`. This is only useful for optimization
  ## purposes.
  when not defined(JS) and not defined(nimscript):
    var s = cast[PGenericSeq](s)
    s.reserved = s.reserved or seqShallowFlag

proc shallow*(s: var string) {.noSideEffect, inline.} =
  ## marks a string `s` as `shallow`:idx:. Subsequent assignments will not
  ## perform deep copies of `s`. This is only useful for optimization
  ## purposes.
  when not defined(JS) and not defined(nimscript):
    var s = cast[PGenericSeq](s)
    s.reserved = s.reserved or seqShallowFlag

type
  NimNodeObj = object

  NimNode* {.magic: "PNimrodNode".} = ref NimNodeObj
    ## represents a Nim AST node. Macros operate on this type.
{.deprecated: [PNimrodNode: NimNode].}

when false:
  template eval*(blk: stmt): stmt =
    ## executes a block of code at compile time just as if it was a macro
    ## optionally, the block can return an AST tree that will replace the
    ## eval expression
    macro payload: stmt {.gensym.} = blk
    payload()

when hasAlloc:
  proc insert*(x: var string, item: string, i = 0.Natural) {.noSideEffect.} =
    ## inserts `item` into `x` at position `i`.
    var xl = x.len
    setLen(x, xl+item.len)
    var j = xl-1
    while j >= i:
      shallowCopy(x[j+item.len], x[j])
      dec(j)
    j = 0
    while j < item.len:
      x[j+i] = item[j]
      inc(j)

proc compiles*(x: expr): bool {.magic: "Compiles", noSideEffect, compileTime.} =
  ## Special compile-time procedure that checks whether `x` can be compiled
  ## without any semantic error.
  ## This can be used to check whether a type supports some operation:
  ##
  ## .. code-block:: Nim
  ##   when not compiles(3 + 4):
  ##     echo "'+' for integers is available"
  discard

when declared(initDebugger):
  initDebugger()

when hasAlloc:
  # XXX: make these the default (or implement the NilObject optimization)
  proc safeAdd*[T](x: var seq[T], y: T) {.noSideEffect.} =
    ## Adds ``y`` to ``x`` unless ``x`` is not yet initialized; in that case,
    ## ``x`` becomes ``@[y]``
    if x == nil: x = @[y]
    else: x.add(y)

  proc safeAdd*(x: var string, y: char) =
    ## Adds ``y`` to ``x``. If ``x`` is ``nil`` it is initialized to ``""``
    if x == nil: x = ""
    x.add(y)

  proc safeAdd*(x: var string, y: string) =
    ## Adds ``y`` to ``x`` unless ``x`` is not yet initalized; in that
    ## case, ``x`` becomes ``y``
    if x == nil: x = y
    else: x.add(y)

proc locals*(): RootObj {.magic: "Plugin", noSideEffect.} =
  ## generates a tuple constructor expression listing all the local variables
  ## in the current scope. This is quite fast as it does not rely
  ## on any debug or runtime information. Note that in constrast to what
  ## the official signature says, the return type is not ``RootObj`` but a
  ## tuple of a structure that depends on the current scope. Example:
  ##
  ## .. code-block:: nim
  ##   proc testLocals() =
  ##     var
  ##       a = "something"
  ##       b = 4
  ##       c = locals()
  ##       d = "super!"
  ##
  ##     b = 1
  ##     for name, value in fieldPairs(c):
  ##       echo "name ", name, " with value ", value
  ##     echo "B is ", b
  ##   # -> name a with value something
  ##   # -> name b with value 4
  ##   # -> B is 1
  discard

when hasAlloc and not defined(nimscript) and not defined(JS):
  proc deepCopy*[T](x: var T, y: T) {.noSideEffect, magic: "DeepCopy".} =
    ## performs a deep copy of `x`. This is also used by the code generator
    ## for the implementation of ``spawn``.
    discard

  include "system/deepcopy"

proc procCall*(x: expr) {.magic: "ProcCall", compileTime.} =
  ## special magic to prohibit dynamic binding for `method`:idx: calls.
  ## This is similar to `super`:idx: in ordinary OO languages.
  ##
  ## .. code-block:: nim
  ##   # 'someMethod' will be resolved fully statically:
  ##   procCall someMethod(a, b)
  discard

proc `^`*[T](x: int; y: openArray[T]): int {.noSideEffect, magic: "Roof".}
proc `^`*(x: int): int {.noSideEffect, magic: "Roof".} =
  ## builtin `roof`:idx: operator that can be used for convenient array access.
  ## ``a[^x]`` is rewritten to ``a[a.len-x]``. However currently the ``a``
  ## expression must not have side effects for this to compile. Note that since
  ## this is a builtin, it automatically works for all kinds of
  ## overloaded ``[]`` or ``[]=`` accessors.
  discard

template `..^`*(a, b: expr): expr =
  ## a shortcut for '.. ^' to avoid the common gotcha that a space between
  ## '..' and '^' is required.
  a .. ^b

template `..<`*(a, b: expr): expr =
  ## a shortcut for '.. <' to avoid the common gotcha that a space between
  ## '..' and '<' is required.
  a .. <b

proc xlen*(x: string): int {.magic: "XLenStr", noSideEffect.} = discard
proc xlen*[T](x: seq[T]): int {.magic: "XLenSeq", noSideEffect.} =
  ## returns the length of a sequence or a string without testing for 'nil'.
  ## This is an optimization that rarely makes sense.
  discard

{.pop.} #{.push warning[GcMem]: off, warning[Uninit]: off.}

when defined(nimconfig):
  include "system/nimscript"

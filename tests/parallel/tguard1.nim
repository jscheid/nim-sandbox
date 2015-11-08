
when false:
  template lock(a, b: ptr TLock; body: stmt) =
    if cast[ByteAddress](a) < cast[ByteAddress](b):
      pthread_mutex_lock(a)
      pthread_mutex_lock(b)
    else:
      pthread_mutex_lock(b)
      pthread_mutex_lock(a)
    {.locks: [a, b].}:
      try:
        body
      finally:
        pthread_mutex_unlock(a)
        pthread_mutex_unlock(b)

type
  ProtectedCounter[T] = object
    i {.guard: L.}: T
    L: int

var
  c: ProtectedCounter[int]

c.i = 89

template atomicRead(L, x): expr =
  {.locks: [L].}:
    x

proc main =
  {.locks: [c.L].}:
    inc c.i
    discard
  echo(atomicRead(c.L, c.i))

main()

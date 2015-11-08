import typetraits

type
  Base = object of RootObj
  Child = object of Base

proc pr(T: typedesc[Base]) = echo "proc " & T.name
method me(T: typedesc[Base]) = echo "method " & T.name
iterator it(T: typedesc[Base]) = yield "yield " & T.name

Base.pr
Child.pr

Base.me
when false:
  Child.me #<- bug #2710

for s in Base.it: echo s
for s in Child.it: echo s #<- bug #2662

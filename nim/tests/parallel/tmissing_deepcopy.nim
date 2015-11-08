discard """
  ccodeCheck: "\\i @'deepCopy(' .*"
"""

# bug #2286

import threadPool

type
  Person = ref object
    name: string
    friend: Person

var
  people: seq[Person] = @[]

proc newPerson(name:string): Person =
  result.new()
  result.name = name

proc greet(p:Person) =
  p.friend.name &= "-MUT" # this line crashes the program
  echo "Person {",
    " name:", p.name, "(", cast[int](addr p.name),"),",
    " friend:", p.friend.name, "(", cast[int](addr p.friend.name),") }"

proc setup =
  for i in 0 .. <20:
    people.add newPerson("Person" & $(i + 1))
  for i in 0 .. <20:
    people[i].friend = people[19-i]

proc update =
  parallel:
    for i in 0 .. people.high:
      spawn people[i].greet()

when isMainModule:
  setup()
  update()

##
## specialised_is_equivalent Nim Module
##
## Created by Eric Doughty-Papassideris on 2011-02-16.

type
  TGen[T] = tuple[a: T]
  TSpef = tuple[a: string]

var
  a: TGen[string]
  b: TSpef
a = b


discard """
  file: "tests/reject/trecincb.nim"
  line: 9
  errormsg: "recursive dependency: 'tests/modules/trecincb.nim'"
"""
# Test recursive includes

include trecincb

echo "trecina"



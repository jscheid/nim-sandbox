discard """
  file: "tnocontains.nim"
  line: 10
  errormsg: "type mismatch: got (string, string)"
"""

# shouldn't compile since it doesn't do what you think it does without
# importing strutils:

let x = "abcdef".contains("abc")
echo x

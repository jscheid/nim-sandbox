import
  commands, lexer, condsyms, options, msgs, nversion, nimconf, ropes,
  extccomp, strutils, os, osproc, platform, main, parseopt, service,
  nodejs, scriptconfig, modules

GC_disable()
GC_disableMarkAndSweep()
  
condsyms.initDefines()

processCmdLine(passCmd1, "") # -d:nodejs --verbosity:3 --stdout 

gProjectName = "examples/hallo.nim"
gProjectFull = canonicalizePath(gProjectName)
gProjectPath = getCurrentDir()

loadConfigs(DefaultConfig) # load all config files

extccomp.initVars()

processCmdLine(passCmd2, "")

#mainCommand()
GC_fullCollect()


proc fib1(a: cint): cint {.exportc.} =
  resetAllModules()
  curCaasCmd = "js -f -d:nodejs examples/hallo.nim"
  processCmdLine(passCmd2, curCaasCmd)
  mainCommand()
  GC_fullCollect()

proc fib2(a: cint): cint {.exportc.} =
  curCaasCmd = "js -f -d:nodejs examples/hallo2.nim"
  processCmdLine(passCmd2, curCaasCmd)
  mainCommand()
  GC_fullCollect()

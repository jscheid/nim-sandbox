import
  commands, lexer, condsyms, options, msgs, nversion, nimconf, ropes,
  extccomp, strutils, os, osproc, platform, main, parseopt, service,
  nodejs, scriptconfig, modules

GC_disable()
GC_disableMarkAndSweep()
  
condsyms.initDefines()

processCmdLine(passCmd1, "")

gProjectName = "main.nim"
gProjectFull = canonicalizePath(gProjectName)
gProjectPath = getCurrentDir()

loadConfigs(DefaultConfig) # load all config files

extccomp.initVars()

processCmdLine(passCmd2, "")

mainCommand()

GC_fullCollect()

proc recompile(cmd: cstring): cint {.exportc.} =
  resetAllModulesHard()
  curCaasCmd = $cmd
  processCmdLine(passCmd2, curCaasCmd)
  mainCommand()
  GC_fullCollect()

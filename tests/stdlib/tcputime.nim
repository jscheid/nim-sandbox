
import times, os

var e = epochTime()
var c = cpuTime()

os.sleep(1500)

e = epochTime() - e
c = cpuTime() - c

echo "epochTime: ", e, " cpuTime: ", c


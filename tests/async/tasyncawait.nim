discard """
  file: "tasyncawait.nim"
  output: "5000"
"""
import asyncdispatch, nativesockets, net, strutils, os

var msgCount = 0

const
  swarmSize = 50
  messagesToSend = 100

var clientCount = 0

proc sendMessages(client: TAsyncFD) {.async.} =
  for i in 0 .. <messagesToSend:
    await send(client, "Message " & $i & "\c\L")

proc launchSwarm(port: TPort) {.async.} =
  for i in 0 .. <swarmSize:
    var sock = newAsyncNativeSocket()

    await connect(sock, "localhost", port)
    await sendMessages(sock)
    closeSocket(sock)

proc readMessages(client: TAsyncFD) {.async.} =
  while true:
    var line = await recvLine(client)
    if line == "":
      closeSocket(client)
      clientCount.inc
      break
    else:
      if line.startswith("Message "):
        msgCount.inc
      else:
        doAssert false

proc createServer(port: TPort) {.async.} =
  var server = newAsyncNativeSocket()
  block:
    var name: Sockaddr_in
    when defined(windows):
      name.sin_family = toInt(AF_INET).int16
    else:
      name.sin_family = toInt(AF_INET)
    name.sin_port = htons(int16(port))
    name.sin_addr.s_addr = htonl(INADDR_ANY)
    if bindAddr(server.SocketHandle, cast[ptr SockAddr](addr(name)),
                sizeof(name).Socklen) < 0'i32:
      raiseOSError(osLastError())

  discard server.SocketHandle.listen()
  while true:
    asyncCheck readMessages(await accept(server))

asyncCheck createServer(TPort(10335))
asyncCheck launchSwarm(TPort(10335))
while true:
  poll()
  if clientCount == swarmSize: break

assert msgCount == swarmSize * messagesToSend
echo msgCount

#
#
#            Nim's Runtime Library
#        (c) Copyright 2015 Dominik Picheta
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.
#

## This module implements a low-level cross-platform sockets interface. Look
## at the ``net`` module for the higher-level version.

# TODO: Clean up the exports a bit and everything else in general.

import unsigned, os

when hostOS == "solaris":
  {.passl: "-lsocket -lnsl".}

const useWinVersion = defined(Windows) or defined(nimdoc)

when useWinVersion:
  import winlean
  export WSAEWOULDBLOCK, WSAECONNRESET, WSAECONNABORTED, WSAENETRESET,
         WSAEDISCON, ERROR_NETNAME_DELETED
else:
  import posix
  export fcntl, F_GETFL, O_NONBLOCK, F_SETFL, EAGAIN, EWOULDBLOCK, MSG_NOSIGNAL,
    EINTR, EINPROGRESS, ECONNRESET, EPIPE, ENETRESET
  export Sockaddr_storage

export SocketHandle, Sockaddr_in, Addrinfo, INADDR_ANY, SockAddr, SockLen,
  Sockaddr_in6,
  inet_ntoa, recv, `==`, connect, send, accept, recvfrom, sendto

export
  SO_ERROR,
  SOL_SOCKET,
  SOMAXCONN,
  SO_ACCEPTCONN, SO_BROADCAST, SO_DEBUG, SO_DONTROUTE,
  SO_KEEPALIVE, SO_OOBINLINE, SO_REUSEADDR,
  MSG_PEEK

when defined(macosx) and not defined(nimdoc):
    export SO_NOSIGPIPE

type
  Port* = distinct uint16  ## port type

  Domain* = enum    ## domain, which specifies the protocol family of the
                    ## created socket. Other domains than those that are listed
                    ## here are unsupported.
    AF_UNIX,        ## for local socket (using a file). Unsupported on Windows.
    AF_INET = 2,    ## for network protocol IPv4 or
    AF_INET6 = 23   ## for network protocol IPv6.

  SockType* = enum     ## second argument to `socket` proc
    SOCK_STREAM = 1,   ## reliable stream-oriented service or Stream Sockets
    SOCK_DGRAM = 2,    ## datagram service or Datagram Sockets
    SOCK_RAW = 3,      ## raw protocols atop the network layer.
    SOCK_SEQPACKET = 5 ## reliable sequenced packet service

  Protocol* = enum      ## third argument to `socket` proc
    IPPROTO_TCP = 6,    ## Transmission control protocol.
    IPPROTO_UDP = 17,   ## User datagram protocol.
    IPPROTO_IP,         ## Internet protocol. Unsupported on Windows.
    IPPROTO_IPV6,       ## Internet Protocol Version 6. Unsupported on Windows.
    IPPROTO_RAW,        ## Raw IP Packets Protocol. Unsupported on Windows.
    IPPROTO_ICMP        ## Control message protocol. Unsupported on Windows.

  Servent* = object ## information about a service
    name*: string
    aliases*: seq[string]
    port*: Port
    proto*: string

  Hostent* = object ## information about a given host
    name*: string
    aliases*: seq[string]
    addrtype*: Domain
    length*: int
    addrList*: seq[string]

{.deprecated: [TPort: Port, TDomain: Domain, TType: SockType,
    TProtocol: Protocol, TServent: Servent, THostent: Hostent].}

when useWinVersion:
  let
    osInvalidSocket* = winlean.INVALID_SOCKET

  const
    IOCPARM_MASK* = 127
    IOC_IN* = int(-2147483648)
    FIONBIO* = IOC_IN.int32 or ((sizeof(int32) and IOCPARM_MASK) shl 16) or
                             (102 shl 8) or 126
    nativeAfInet = winlean.AF_INET
    nativeAfInet6 = winlean.AF_INET6

  proc ioctlsocket*(s: SocketHandle, cmd: clong,
                   argptr: ptr clong): cint {.
                   stdcall, importc: "ioctlsocket", dynlib: "ws2_32.dll".}
else:
  let
    osInvalidSocket* = posix.INVALID_SOCKET
    nativeAfInet = posix.AF_INET
    nativeAfInet6 = posix.AF_INET6

proc `==`*(a, b: Port): bool {.borrow.}
  ## ``==`` for ports.

proc `$`*(p: Port): string {.borrow.}
  ## returns the port number as a string

proc toInt*(domain: Domain): cint
  ## Converts the Domain enum to a platform-dependent ``cint``.

proc toInt*(typ: SockType): cint
  ## Converts the SockType enum to a platform-dependent ``cint``.

proc toInt*(p: Protocol): cint
  ## Converts the Protocol enum to a platform-dependent ``cint``.

when not useWinVersion:
  proc toInt(domain: Domain): cint =
    case domain
    of AF_UNIX:        result = posix.AF_UNIX
    of AF_INET:        result = posix.AF_INET
    of AF_INET6:       result = posix.AF_INET6
    else: discard

  proc toInt(typ: SockType): cint =
    case typ
    of SOCK_STREAM:    result = posix.SOCK_STREAM
    of SOCK_DGRAM:     result = posix.SOCK_DGRAM
    of SOCK_SEQPACKET: result = posix.SOCK_SEQPACKET
    of SOCK_RAW:       result = posix.SOCK_RAW
    else: discard

  proc toInt(p: Protocol): cint =
    case p
    of IPPROTO_TCP:    result = posix.IPPROTO_TCP
    of IPPROTO_UDP:    result = posix.IPPROTO_UDP
    of IPPROTO_IP:     result = posix.IPPROTO_IP
    of IPPROTO_IPV6:   result = posix.IPPROTO_IPV6
    of IPPROTO_RAW:    result = posix.IPPROTO_RAW
    of IPPROTO_ICMP:   result = posix.IPPROTO_ICMP
    else: discard

else:
  proc toInt(domain: Domain): cint =
    result = toU16(ord(domain))

  proc toInt(typ: SockType): cint =
    result = cint(ord(typ))

  proc toInt(p: Protocol): cint =
    result = cint(ord(p))


proc newNativeSocket*(domain: Domain = AF_INET,
                      sockType: SockType = SOCK_STREAM,
                      protocol: Protocol = IPPROTO_TCP): SocketHandle =
  ## Creates a new socket; returns `InvalidSocket` if an error occurs.
  socket(toInt(domain), toInt(sockType), toInt(protocol))

proc newNativeSocket*(domain: cint, sockType: cint,
                      protocol: cint): SocketHandle =
  ## Creates a new socket; returns `InvalidSocket` if an error occurs.
  ##
  ## Use this overload if one of the enums specified above does
  ## not contain what you need.
  socket(domain, sockType, protocol)

proc close*(socket: SocketHandle) =
  ## closes a socket.
  when useWinVersion:
    discard winlean.closesocket(socket)
  else:
    discard posix.close(socket)
  # TODO: These values should not be discarded. An EOS should be raised.
  # http://stackoverflow.com/questions/12463473/what-happens-if-you-call-close-on-a-bsd-socket-multiple-times

proc bindAddr*(socket: SocketHandle, name: ptr SockAddr, namelen: SockLen): cint =
  result = bindSocket(socket, name, namelen)

proc listen*(socket: SocketHandle, backlog = SOMAXCONN): cint {.tags: [ReadIOEffect].} =
  ## Marks ``socket`` as accepting connections.
  ## ``Backlog`` specifies the maximum length of the
  ## queue of pending connections.
  when useWinVersion:
    result = winlean.listen(socket, cint(backlog))
  else:
    result = posix.listen(socket, cint(backlog))

proc getAddrInfo*(address: string, port: Port, domain: Domain = AF_INET,
                  sockType: SockType = SOCK_STREAM,
                  protocol: Protocol = IPPROTO_TCP): ptr AddrInfo =
  ##
  ##
  ## **Warning**: The resulting ``ptr TAddrInfo`` must be freed using ``dealloc``!
  var hints: AddrInfo
  result = nil
  hints.ai_family = toInt(domain)
  hints.ai_socktype = toInt(sockType)
  hints.ai_protocol = toInt(protocol)
  # https://bugs.freebsd.org/bugzilla/show_bug.cgi?id=198092
  when not defined(freebsd):
    hints.ai_flags = AI_V4MAPPED
  var gaiResult = getaddrinfo(address, $port, addr(hints), result)
  if gaiResult != 0'i32:
    when useWinVersion:
      raiseOSError(osLastError())
    else:
      raiseOSError(osLastError(), $gai_strerror(gaiResult))

proc dealloc*(ai: ptr AddrInfo) =
  freeaddrinfo(ai)

proc ntohl*(x: int32): int32 =
  ## Converts 32-bit integers from network to host byte order.
  ## On machines where the host byte order is the same as network byte order,
  ## this is a no-op; otherwise, it performs a 4-byte swap operation.
  when cpuEndian == bigEndian: result = x
  else: result = (x shr 24'i32) or
                 (x shr 8'i32 and 0xff00'i32) or
                 (x shl 8'i32 and 0xff0000'i32) or
                 (x shl 24'i32)

proc ntohs*(x: int16): int16 =
  ## Converts 16-bit integers from network to host byte order. On machines
  ## where the host byte order is the same as network byte order, this is
  ## a no-op; otherwise, it performs a 2-byte swap operation.
  when cpuEndian == bigEndian: result = x
  else: result = (x shr 8'i16) or (x shl 8'i16)

template htonl*(x: int32): expr =
  ## Converts 32-bit integers from host to network byte order. On machines
  ## where the host byte order is the same as network byte order, this is
  ## a no-op; otherwise, it performs a 4-byte swap operation.
  nativesockets.ntohl(x)

template htons*(x: int16): expr =
  ## Converts 16-bit positive integers from host to network byte order.
  ## On machines where the host byte order is the same as network byte
  ## order, this is a no-op; otherwise, it performs a 2-byte swap operation.
  nativesockets.ntohs(x)

proc getServByName*(name, proto: string): Servent {.tags: [ReadIOEffect].} =
  ## Searches the database from the beginning and finds the first entry for
  ## which the service name specified by ``name`` matches the s_name member
  ## and the protocol name specified by ``proto`` matches the s_proto member.
  ##
  ## On posix this will search through the ``/etc/services`` file.
  when useWinVersion:
    var s = winlean.getservbyname(name, proto)
  else:
    var s = posix.getservbyname(name, proto)
  if s == nil: raiseOSError(osLastError(), "Service not found.")
  result.name = $s.s_name
  result.aliases = cstringArrayToSeq(s.s_aliases)
  result.port = Port(s.s_port)
  result.proto = $s.s_proto

proc getServByPort*(port: Port, proto: string): Servent {.tags: [ReadIOEffect].} =
  ## Searches the database from the beginning and finds the first entry for
  ## which the port specified by ``port`` matches the s_port member and the
  ## protocol name specified by ``proto`` matches the s_proto member.
  ##
  ## On posix this will search through the ``/etc/services`` file.
  when useWinVersion:
    var s = winlean.getservbyport(ze(int16(port)).cint, proto)
  else:
    var s = posix.getservbyport(ze(int16(port)).cint, proto)
  if s == nil: raiseOSError(osLastError(), "Service not found.")
  result.name = $s.s_name
  result.aliases = cstringArrayToSeq(s.s_aliases)
  result.port = Port(s.s_port)
  result.proto = $s.s_proto

proc getHostByAddr*(ip: string): Hostent {.tags: [ReadIOEffect].} =
  ## This function will lookup the hostname of an IP Address.
  var myaddr: InAddr
  myaddr.s_addr = inet_addr(ip)

  when useWinVersion:
    var s = winlean.gethostbyaddr(addr(myaddr), sizeof(myaddr).cuint,
                                  cint(AF_INET))
    if s == nil: raiseOSError(osLastError())
  else:
    var s = posix.gethostbyaddr(addr(myaddr), sizeof(myaddr).Socklen,
                                cint(posix.AF_INET))
    if s == nil:
      raiseOSError(osLastError(), $hstrerror(h_errno))

  result.name = $s.h_name
  result.aliases = cstringArrayToSeq(s.h_aliases)
  when useWinVersion:
    result.addrtype = Domain(s.h_addrtype)
  else:
    if s.h_addrtype == posix.AF_INET:
      result.addrtype = AF_INET
    elif s.h_addrtype == posix.AF_INET6:
      result.addrtype = AF_INET6
    else:
      raiseOSError(osLastError(), "unknown h_addrtype")
  result.addrList = cstringArrayToSeq(s.h_addr_list)
  result.length = int(s.h_length)

proc getHostByName*(name: string): Hostent {.tags: [ReadIOEffect].} =
  ## This function will lookup the IP address of a hostname.
  when useWinVersion:
    var s = winlean.gethostbyname(name)
  else:
    var s = posix.gethostbyname(name)
  if s == nil: raiseOSError(osLastError())
  result.name = $s.h_name
  result.aliases = cstringArrayToSeq(s.h_aliases)
  when useWinVersion:
    result.addrtype = Domain(s.h_addrtype)
  else:
    if s.h_addrtype == posix.AF_INET:
      result.addrtype = AF_INET
    elif s.h_addrtype == posix.AF_INET6:
      result.addrtype = AF_INET6
    else:
      raiseOSError(osLastError(), "unknown h_addrtype")
  result.addrList = cstringArrayToSeq(s.h_addr_list)
  result.length = int(s.h_length)

proc getSockDomain*(socket: SocketHandle): Domain =
  ## returns the socket's domain (AF_INET or AF_INET6).
  var name: SockAddr
  var namelen = sizeof(name).SockLen
  if getsockname(socket, cast[ptr SockAddr](addr(name)),
                 addr(namelen)) == -1'i32:
    raiseOSError(osLastError())
  if name.sa_family == nativeAfInet:
    result = AF_INET
  elif name.sa_family == nativeAfInet6:
    result = AF_INET6
  else:
    raiseOSError(osLastError(), "unknown socket family in getSockFamily")


proc getAddrString*(sockAddr: ptr SockAddr): string =
  ## return the string representation of address within sockAddr
  if sockAddr.sa_family == nativeAfInet:
    result = $inet_ntoa(cast[ptr Sockaddr_in](sockAddr).sin_addr)
  elif sockAddr.sa_family == nativeAfInet6:
    when not useWinVersion:
      # TODO: Windows
      result = newString(posix.INET6_ADDRSTRLEN)
      let addr6 = addr cast[ptr Sockaddr_in6](sockAddr).sin6_addr
      discard posix.inet_ntop(posix.AF_INET6, addr6, result.cstring,
          result.len.int32)
      if posix.IN6_IS_ADDR_V4MAPPED(addr6) != 0:
        result = result.substr("::ffff:".len)
  else:
    raiseOSError(osLastError(), "unknown socket family in getAddrString")


proc getSockName*(socket: SocketHandle): Port =
  ## returns the socket's associated port number.
  var name: Sockaddr_in
  when useWinVersion:
    name.sin_family = int16(ord(AF_INET))
  else:
    name.sin_family = posix.AF_INET
  #name.sin_port = htons(cint16(port))
  #name.sin_addr.s_addr = htonl(INADDR_ANY)
  var namelen = sizeof(name).SockLen
  if getsockname(socket, cast[ptr SockAddr](addr(name)),
                 addr(namelen)) == -1'i32:
    raiseOSError(osLastError())
  result = Port(nativesockets.ntohs(name.sin_port))

proc getLocalAddr*(socket: SocketHandle, domain: Domain): (string, Port) =
  ## returns the socket's local address and port number.
  ##
  ## Similar to POSIX's `getsockname`:idx:.
  case domain
  of AF_INET:
    var name: Sockaddr_in
    when useWinVersion:
      name.sin_family = int16(ord(AF_INET))
    else:
      name.sin_family = posix.AF_INET
    var namelen = sizeof(name).SockLen
    if getsockname(socket, cast[ptr SockAddr](addr(name)),
                   addr(namelen)) == -1'i32:
      raiseOSError(osLastError())
    result = ($inet_ntoa(name.sin_addr),
              Port(nativesockets.ntohs(name.sin_port)))
  of AF_INET6:
    var name: Sockaddr_in6
    when useWinVersion:
      name.sin6_family = int16(ord(AF_INET6))
    else:
      name.sin6_family = posix.AF_INET6
    var namelen = sizeof(name).SockLen
    if getsockname(socket, cast[ptr SockAddr](addr(name)),
                   addr(namelen)) == -1'i32:
      raiseOSError(osLastError())
    # Cannot use INET6_ADDRSTRLEN here, because it's a C define.
    var buf: array[64, char]
    if inet_ntop(name.sin6_family.cint,
                 addr name, buf.cstring, sizeof(buf).int32).isNil:
      raiseOSError(osLastError())
    result = ($buf, Port(nativesockets.ntohs(name.sin6_port)))
  else:
    raiseOSError(OSErrorCode(-1), "invalid socket family in getLocalAddr")

proc getPeerAddr*(socket: SocketHandle, domain: Domain): (string, Port) =
  ## returns the socket's peer address and port number.
  ##
  ## Similar to POSIX's `getpeername`:idx:
  case domain
  of AF_INET:
    var name: Sockaddr_in
    when useWinVersion:
      name.sin_family = int16(ord(AF_INET))
    else:
      name.sin_family = posix.AF_INET
    var namelen = sizeof(name).SockLen
    if getpeername(socket, cast[ptr SockAddr](addr(name)),
                   addr(namelen)) == -1'i32:
      raiseOSError(osLastError())
    result = ($inet_ntoa(name.sin_addr),
              Port(nativesockets.ntohs(name.sin_port)))
  of AF_INET6:
    var name: Sockaddr_in6
    when useWinVersion:
      name.sin6_family = int16(ord(AF_INET6))
    else:
      name.sin6_family = posix.AF_INET6
    var namelen = sizeof(name).SockLen
    if getpeername(socket, cast[ptr SockAddr](addr(name)),
                   addr(namelen)) == -1'i32:
      raiseOSError(osLastError())
    # Cannot use INET6_ADDRSTRLEN here, because it's a C define.
    var buf: array[64, char]
    if inet_ntop(name.sin6_family.cint,
                 addr name, buf.cstring, sizeof(buf).int32).isNil:
      raiseOSError(osLastError())
    result = ($buf, Port(nativesockets.ntohs(name.sin6_port)))
  else:
    raiseOSError(OSErrorCode(-1), "invalid socket family in getLocalAddr")

proc getSockOptInt*(socket: SocketHandle, level, optname: int): int {.
  tags: [ReadIOEffect].} =
  ## getsockopt for integer options.
  var res: cint
  var size = sizeof(res).SockLen
  if getsockopt(socket, cint(level), cint(optname),
                addr(res), addr(size)) < 0'i32:
    raiseOSError(osLastError())
  result = int(res)

proc setSockOptInt*(socket: SocketHandle, level, optname, optval: int) {.
  tags: [WriteIOEffect].} =
  ## setsockopt for integer options.
  var value = cint(optval)
  if setsockopt(socket, cint(level), cint(optname), addr(value),
                sizeof(value).SockLen) < 0'i32:
    raiseOSError(osLastError())

proc setBlocking*(s: SocketHandle, blocking: bool) =
  ## Sets blocking mode on socket.
  ##
  ## Raises EOS on error.
  when useWinVersion:
    var mode = clong(ord(not blocking)) # 1 for non-blocking, 0 for blocking
    if ioctlsocket(s, FIONBIO, addr(mode)) == -1:
      raiseOSError(osLastError())
  else: # BSD sockets
    var x: int = fcntl(s, F_GETFL, 0)
    if x == -1:
      raiseOSError(osLastError())
    else:
      var mode = if blocking: x and not O_NONBLOCK else: x or O_NONBLOCK
      if fcntl(s, F_SETFL, mode) == -1:
        raiseOSError(osLastError())

proc timeValFromMilliseconds(timeout = 500): Timeval =
  if timeout != -1:
    var seconds = timeout div 1000
    result.tv_sec = seconds.int32
    result.tv_usec = ((timeout - seconds * 1000) * 1000).int32

proc createFdSet(fd: var TFdSet, s: seq[SocketHandle], m: var int) =
  FD_ZERO(fd)
  for i in items(s):
    m = max(m, int(i))
    FD_SET(i, fd)

proc pruneSocketSet(s: var seq[SocketHandle], fd: var TFdSet) =
  var i = 0
  var L = s.len
  while i < L:
    if FD_ISSET(s[i], fd) == 0'i32:
      s[i] = s[L-1]
      dec(L)
    else:
      inc(i)
  setLen(s, L)

proc select*(readfds: var seq[SocketHandle], timeout = 500): int =
  ## Traditional select function. This function will return the number of
  ## sockets that are ready to be read from, written to, or which have errors.
  ## If there are none; 0 is returned.
  ## ``Timeout`` is in milliseconds and -1 can be specified for no timeout.
  ##
  ## A socket is removed from the specific ``seq`` when it has data waiting to
  ## be read/written to or has errors (``exceptfds``).
  var tv {.noInit.}: Timeval = timeValFromMilliseconds(timeout)

  var rd: TFdSet
  var m = 0
  createFdSet((rd), readfds, m)

  if timeout != -1:
    result = int(select(cint(m+1), addr(rd), nil, nil, addr(tv)))
  else:
    result = int(select(cint(m+1), addr(rd), nil, nil, nil))

  pruneSocketSet(readfds, (rd))

proc selectWrite*(writefds: var seq[SocketHandle],
                  timeout = 500): int {.tags: [ReadIOEffect].} =
  ## When a socket in ``writefds`` is ready to be written to then a non-zero
  ## value will be returned specifying the count of the sockets which can be
  ## written to. The sockets which can be written to will also be removed
  ## from ``writefds``.
  ##
  ## ``timeout`` is specified in milliseconds and ``-1`` can be specified for
  ## an unlimited time.
  var tv {.noInit.}: Timeval = timeValFromMilliseconds(timeout)

  var wr: TFdSet
  var m = 0
  createFdSet((wr), writefds, m)

  if timeout != -1:
    result = int(select(cint(m+1), nil, addr(wr), nil, addr(tv)))
  else:
    result = int(select(cint(m+1), nil, addr(wr), nil, nil))

  pruneSocketSet(writefds, (wr))

when defined(Windows):
  var wsa: WSAData
  if wsaStartup(0x0101'i16, addr wsa) != 0: raiseOSError(osLastError())

## Private Unix-socket transport. No GUI imports or implicit instance discovery.
import std/[json, monotimes, nativesockets, net, os, strutils, times]
import ./protocol

when defined(posix):
  import std/posix

const
  DevMaxClients = 4
  DevIoTimeout = initDuration(seconds = 15)
  DevChunkBytes = 64 * 1024
  DevMaxSocketPath =
    when defined(posix):
      min(100, Sockaddr_un_path_length - 1)
    else:
      100

type
  DevCompletion* = proc(response: DevResponse) {.closure.}
  DevHandler* = proc(request: DevRequest, complete: DevCompletion) {.closure.}

  DevConnection = ref object
    socket: Socket
    input, output: string
    sent: int
    dispatched, closed: bool
    deadline: MonoTime

  DevServer* = ref object
    socket: Socket
    path: string
    clients: seq[DevConnection]
    handler: DevHandler
    closed: bool
    when defined(posix):
      device: Dev
      inode: Ino

proc devSocketPath*(pid: Positive): string =
  ## Deterministic per-user address, independent of the caller's TMPDIR.
  when defined(posix):
    "/tmp/merenda-dev-" & $getuid() & "/" & $pid & ".sock"
  else:
    raise newException(OSError, "Development control requires Unix sockets")

proc close(connection: DevConnection) =
  if not connection.closed:
    connection.closed = true
    connection.socket.close()
    connection.output.setLen(0)

proc close*(server: DevServer) =
  ## Closes clients and removes only the socket inode created by this server.
  if server.isNil or server.closed:
    return
  server.closed = true
  for connection in server.clients:
    connection.close()
  server.clients.setLen(0)
  server.handler = nil
  server.socket.close()
  when defined(posix):
    var status: Stat
    if lstat(server.path.cstring, status) == 0 and status.st_dev == server.device and
        status.st_ino == server.inode:
      discard unlink(server.path.cstring)

proc validateSocketPath(path: string) =
  if not path.isAbsolute() or path.len > DevMaxSocketPath or '\0' in path:
    raise newException(
      ValueError,
      "Socket path must be absolute and at most " & $DevMaxSocketPath & " bytes",
    )

proc startDevServer*(path: string, handler: DevHandler): DevServer =
  ## Refuses occupied paths and directories not privately owned by this user.
  when defined(posix):
    validateSocketPath(path)
    let directory = path.parentDir()
    if directory == devSocketPath(getCurrentProcessId().Positive).parentDir():
      if posix.mkdir(directory.cstring, Mode(0o700)) != 0 and
          osLastError() != OSErrorCode(EEXIST):
        raiseOSError(osLastError())
    var status: Stat
    if lstat(directory.cstring, status) != 0:
      raiseOSError(osLastError())
    if not S_ISDIR(status.st_mode) or status.st_uid != getuid() or
        (status.st_mode and Mode(0o077)) != 0:
      raise newException(
        OSError, "Socket directory must be owned by this user with mode 0700"
      )
    let socket =
      newSocket(AF_UNIX, SOCK_STREAM, nativesockets.IPPROTO_NONE, buffered = false)
    var bound = false
    try:
      socket.bindUnix(path)
      bound = true
      if chmod(path.cstring, Mode(0o600)) != 0:
        raiseOSError(osLastError())
      if lstat(path.cstring, status) != 0:
        raiseOSError(osLastError())
      socket.listen(DevMaxClients)
      socket.getFd().setBlocking(false)
      result = DevServer(
        socket: socket,
        path: path,
        handler: handler,
        device: status.st_dev,
        inode: status.st_ino,
      )
    except:
      socket.close()
      if bound:
        discard unlink(path.cstring)
      raise
  else:
    raise newException(OSError, "Development control requires Unix sockets")

proc queueResponse(connection: DevConnection, response: DevResponse) =
  if connection.closed or connection.output.len > 0:
    return
  connection.output = $response.responseJson() & "\n"
  if connection.output.len > DevMaxResponseBytes:
    connection.output =
      $devFailure(response.id, "capture_failed", "Response exceeds size limit")
        .responseJson() & "\n"
  connection.deadline = getMonoTime() + DevIoTimeout

proc socketWouldBlock(): bool =
  when defined(posix):
    let error = osLastError()
    error in [OSErrorCode(EAGAIN), OSErrorCode(EWOULDBLOCK), OSErrorCode(EINTR)]

proc poll*(server: DevServer) =
  ## Bounded, nonblocking work on the application's owning thread.
  if server.isNil or server.closed:
    return
  var handles = @[server.socket.getFd()]
  if server.clients.len < DevMaxClients and selectRead(handles, 0) > 0:
    try:
      var client: owned(Socket)
      server.socket.accept(client)
      client.getFd().setBlocking(false)
      server.clients.add DevConnection(
        socket: client, deadline: getMonoTime() + DevIoTimeout
      )
    except OSError:
      discard # Readiness can be interrupted before accept completes.
  var index = 0
  while index < server.clients.len:
    let connection = server.clients[index]
    try:
      if getMonoTime() >= connection.deadline:
        connection.close()
      elif connection.output.len > 0:
        var writable = @[connection.socket.getFd()]
        if selectWrite(writable, 0) > 0:
          let count = min(DevChunkBytes, connection.output.len - connection.sent)
          let sent =
            connection.socket.send(unsafeAddr connection.output[connection.sent], count)
          if sent > 0:
            connection.sent += sent
            connection.deadline = getMonoTime() + DevIoTimeout
            if connection.sent == connection.output.len:
              connection.close()
          elif sent == 0 or not socketWouldBlock():
            connection.close()
      elif connection.dispatched:
        var readable = @[connection.socket.getFd()]
        if selectRead(readable, 0) > 0:
          connection.close() # EOF or additional input after the single request.
      elif not connection.dispatched:
        var readable = @[connection.socket.getFd()]
        if selectRead(readable, 0) > 0:
          var chunk = newString(DevChunkBytes)
          let received = connection.socket.recv(addr chunk[0], chunk.len)
          if received <= 0:
            connection.close()
          else:
            chunk.setLen(received)
            connection.input.add chunk
            if connection.input.len > DevMaxRequestBytes:
              connection.dispatched = true
              connection.queueResponse(
                devFailure("", "invalid_request", "Request is too large")
              )
            elif '\n' in connection.input:
              connection.dispatched = true
              let line = connection.input[0 ..< connection.input.find('\n')]
              var id: string
              try:
                let root = parseJson(line)
                if root.kind == JObject and root.hasKey("id") and
                    root["id"].kind == JString:
                  id = root["id"].getStr()
                let request = parseDevRequest(line)
                try:
                  server.handler(
                    request,
                    proc(response: DevResponse) =
                      connection.queueResponse(response),
                  )
                except CatchableError as error:
                  connection.queueResponse(devFailure(id, "internal_error", error.msg))
              except DevProtocolError as error:
                connection.queueResponse(devFailure(id, error.code, error.msg))
              except CatchableError as error:
                connection.queueResponse(devFailure(id, "invalid_request", error.msg))
    except CatchableError:
      connection.close()
    if connection.closed:
      server.clients.delete(index)
    else:
      inc index

proc sendDevRequest*(path: string, request: DevRequest, timeoutMs = 15000): JsonNode =
  ## Sends once. A timeout never retries a possibly executed input command.
  when defined(posix):
    validateSocketPath(path)
    if timeoutMs <= 0:
      raise newException(ValueError, "Timeout must be positive")
    let socket =
      newSocket(AF_UNIX, SOCK_STREAM, nativesockets.IPPROTO_NONE, buffered = false)
    defer:
      socket.close()
    socket.getFd().setBlocking(false)
    socket.connectUnix(path)
    let deadline = getMonoTime() + initDuration(milliseconds = timeoutMs)
    let message = $request.requestJson() & "\n"
    var sent = 0
    var input: string
    while getMonoTime() < deadline:
      if sent < message.len:
        var writable = @[socket.getFd()]
        if selectWrite(writable, 20) > 0:
          let count = socket.send(unsafeAddr message[sent], message.len - sent)
          if count > 0:
            sent += count
          elif count == 0:
            raise newException(IOError, "Control connection closed while sending")
          elif not socketWouldBlock():
            raiseOSError(osLastError())
      else:
        var readable = @[socket.getFd()]
        if selectRead(readable, 20) > 0:
          var chunk = newString(DevChunkBytes)
          let received = socket.recv(addr chunk[0], chunk.len)
          if received == 0:
            raise newException(IOError, "Control connection closed before its response")
          if received < 0:
            if socketWouldBlock():
              continue
            raiseOSError(osLastError())
          chunk.setLen(received)
          input.add chunk
          if input.len > DevMaxResponseBytes:
            raise newException(IOError, "Control response exceeds size limit")
          let newline = input.find('\n')
          if newline >= 0:
            result = parseJson(input[0 ..< newline])
            if result.kind != JObject or not result.hasKey("version") or
                result["version"] != %DevProtocolVersion or
                result.getOrDefault("id") != %request.id or not result.hasKey("ok") or
                result["ok"].kind != JBool:
              raise newException(IOError, "Invalid control response")
            return
    raise newException(
      IOError, "Control request timed out; execution may already have occurred"
    )
  else:
    raise newException(OSError, "Development control requires Unix sockets")

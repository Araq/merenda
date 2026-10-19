# Development control

Build any Merenda application with `-d:merendaDevControl` to include an optional
local automation endpoint. Production builds omit the listener, dispatch adapter
and capture queues. The environment cannot enable an uninstrumented build.

```sh
nim ic -d:merendaDevControl examples/controls_showcase.nim
nim ic -o:deps/merenda-dev tools/merenda_dev.nim
MERENDA_DEV_CONTROL=1 MERENDA_BACKGROUND=1 ./examples/controls_showcase &
app_pid=$!
./deps/merenda-dev --pid "$app_pid" windows
./deps/merenda-dev --pid "$app_pid" screenshot --window w1 --output /tmp/showcase.png
./deps/merenda-dev --pid "$app_pid" pointer --window w1 --action click --x 80 --y 100
./deps/merenda-dev --pid "$app_pid" key --window w1 --action down --key a --modifiers command
./deps/merenda-dev --pid "$app_pid" text --window w1 --text 'Hello from automation'
kill "$app_pid"
wait "$app_pid"
```

`MERENDA_BACKGROUND=1` shows windows without explicit application activation or
key-window ordering on macOS and uses nonactivating presentation on Windows. It
also applies to later windows and popup hosts. Windows remain eligible for normal
user interaction. This is a visible application, and `&` handles shell detachment.
Linux/BSD window managers retain control of activation; this version does not
promise focus preservation there. The control transport currently supports macOS,
Linux and BSD Unix sockets; Windows transport is deferred.

The server starts when the application event loop is prepared and stops when
`Application.run` exits normally. `runForFrames` also pumps control requests; users
of that API must call `app.stopDevControl()` during teardown. Embedders can import
`merenda/nimkit/app/devcontrol` and call
`app.startDevControl(DevControlOptions(socketPath: path))` explicitly.

## Addresses and transport

The client requires exactly one destination: `--pid PID` or `--socket PATH`.
There is no registry, current-instance selection or broadcast. The default socket
is `/tmp/merenda-dev-<uid>/<pid>.sock`. Set `MERENDA_DEV_SOCKET` to an absolute path
to enable the server at another address, then use `--socket` on the client. Its
parent directory must already exist, belong to the current user, and have no
group/other permissions (normally mode 0700). Paths must fit the native socket-path limit (currently 91 bytes with Nim on
macOS, up to 100 elsewhere); the client reports the applicable limit.

Sockets have mode 0600. An occupied address is an error; the server never removes
an existing address to start. After an abnormal exit, remove a stale socket only
after verifying the process is gone. Normal shutdown removes only the inode the
server created. Local processes running as the same user are trusted.

The server handles at most four connections and four captures at a time. Requests
are limited to 128 KiB, responses to 32 MiB, and images to eight million pixels.
Socket work is nonblocking and bounded per application frame, including partial
writes. Instrumented applications with an enabled endpoint poll at most every
20 ms; an idle production build has no polling cost. Captures have a ten-second
deadline; connections have a fifteen-second deadline, extended by output progress.
The CLI accepts `--timeout MS` (default 15000). **A timeout does not prove a
mutating command was undelivered. Clients must not automatically retry input.**

## Commands and screenshot semantics

`info` reports PID, protocol version, capabilities and background presentation.
`windows` reports opaque IDs, titles, logical content dimensions, content scale,
visibility, native readiness, logical key-window state and modal blocking. Popup
hosts are included. IDs last for one server instance, are never reused, and do not
depend on titles or memory addresses.

`screenshot` requests a fresh rendered frame after the command is accepted. The
response contains base64 PNG bytes, pixel dimensions, scale, and the completed
render ID. `--output` writes
those bytes in the **client process**; the app accepts no output file path. Images
contain the rendered client area at backing-pixel resolution with a top-left
origin. Capture happens on the renderer's owning thread before presentation, for
both main-thread and dedicated rendering. The flag enables Vulkan readback via
this repository's `config.nims`; downstream projects using Vulkan must also set
`-d:figdraw.vulkanReadback=on` in their build configuration.

Captures exclude native titlebars, desktop contents, OS shadows, system menus,
and native backdrop/blur effects. Hidden, minimized, closed or unrealized windows
are unavailable and are never shown implicitly. A fresh frame is a rendering
barrier, not a guarantee that loaders, jobs or animations have become idle.

`pointer` supports `move`, `down`, `up`, `drag`, `click`, and `scroll`. Coordinates
are logical content coordinates; optional buttons are `primary`, `secondary`, or
`other`. Scroll uses `--delta-x` and `--delta-y`. `key` supports `down` and `up` with
case-insensitive NimKit key names without the `key` prefix, such as `a`, `enter`,
`arrowleft`, `backspace`, and `escape`. Modifiers are comma-separated `shift`,
`control`, `option`, and `command`. `text` commits UTF-8 text to the responder; it
does not simulate IME composition. Input follows ordinary NimKit dispatch and
rejects modal-blocked windows. Responses distinguish successful delivery from the
`handled` boolean returned by the responder.

## Protocol and future adapters

The transport is one JSON line per request and response, then connection close:

```json
{"version":1,"id":"r1","command":"screenshot","params":{"window":"w1"}}
{"version":1,"id":"r1","ok":true,"result":{"mimeType":"image/png","width":640,"height":480,"scale":2,"data":"..."}}
```

Failures use stable string codes:

```json
{"version":1,"id":"r1","ok":false,"error":{"code":"window_not_found","message":"Window is unavailable: w1"}}
```

The public `DevRequest`, `DevResponse`, and codecs live in
`merenda/nimkit/devcontrol/protocol`; `devSocketPath` and `sendDevRequest` live in
`merenda/nimkit/devcontrol/transport`. These modules have no GUI dependencies.
A future MCP server can translate tools into typed requests and return the PNG
payload directly, without screen-capture permissions or a shell subprocess.
Protocol versioning, explicit instance addressing and structured errors form the
adapter boundary. Discovery, view selectors, accessibility trees, OS-level input,
native-menu automation and an MCP server itself are deferred.

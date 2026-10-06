extends Node
## Test-only HTTP/1.1 server on 127.0.0.1 for exercising the real OTA update client (scripts/boot/ota_updater.gd)
## in the unit suite. Each path can answer normally, hang (accept, never reply), be cut off halfway through its
## body, close without answering, redirect to another path, or 404. Pure GDScript (TCPServer), polled from the
## main loop; never touches the network beyond loopback.

## path -> body bytes
var routes: Dictionary = {}
## path -> "ok" | "hang" | "truncate" | "drop" | "redirect" | "404"
var modes: Dictionary = {}
## path -> target path (for mode "redirect")
var redirects: Dictionary = {}
var port := 0
var requests: Array[String] = []
var hits: Dictionary = {}
var _server: TCPServer = TCPServer.new()
var _conns: Array = []


func start() -> int:
	process_mode = Node.PROCESS_MODE_ALWAYS
	for p in range(18500, 18700):
		if _server.listen(p, "127.0.0.1") == OK:
			port = p
			return p
	return 0


func url(path: String) -> String:
	return "http://127.0.0.1:%d%s" % [port, path]


func hit_count(path: String) -> int:
	return int(hits.get(path, 0))


func _process(_dt: float) -> void:
	while _server.is_listening() and _server.is_connection_available():
		_conns.append({"peer": _server.take_connection(), "buf": PackedByteArray(), "done": false})
	for c in _conns:
		var peer: StreamPeerTCP = c["peer"]
		peer.poll()
		if c["done"] or peer.get_status() != StreamPeerTCP.STATUS_CONNECTED:
			continue
		var n: int = peer.get_available_bytes()
		if n > 0:
			# Packed arrays are values: append to a copy, then store it back.
			var buf: PackedByteArray = c["buf"]
			buf.append_array(peer.get_data(n)[1])
			c["buf"] = buf
		var head: String = (c["buf"] as PackedByteArray).get_string_from_utf8()
		if head.contains("\r\n\r\n"):
			c["done"] = true
			var path: String = head.get_slice(" ", 1).get_slice("?", 0)
			requests.append(path)
			hits[path] = int(hits.get(path, 0)) + 1
			_respond(peer, path)
	_conns = _conns.filter(func(c: Dictionary) -> bool: return (c["peer"] as StreamPeerTCP).get_status() == StreamPeerTCP.STATUS_CONNECTED)


func _respond(peer: StreamPeerTCP, path: String) -> void:
	var mode: String = modes.get(path, "ok")
	if mode == "hang":
		return
	if mode == "drop":
		peer.disconnect_from_host()
		return
	if mode == "redirect":
		peer.put_data(("HTTP/1.1 302 Found\r\nLocation: %s\r\nContent-Length: 0\r\nConnection: close\r\n\r\n" % url(str(redirects.get(path, "/"))) ).to_utf8_buffer())
		peer.disconnect_from_host()
		return
	if mode == "404" or not routes.has(path):
		peer.put_data("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".to_utf8_buffer())
		peer.disconnect_from_host()
		return
	var body: PackedByteArray = routes[path]
	peer.put_data(("HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\nContent-Length: %d\r\nConnection: close\r\n\r\n" % body.size()).to_utf8_buffer())
	peer.put_data(body.slice(0, body.size() / 2) if mode == "truncate" else body)
	peer.disconnect_from_host()


func stop() -> void:
	for c in _conns:
		(c["peer"] as StreamPeerTCP).disconnect_from_host()
	_conns.clear()
	_server.stop()

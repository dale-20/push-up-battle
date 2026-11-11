class_name LanDiscovery
extends RefCounted

## Finds Push-Up Battle hosts on the local network: the same Wi-Fi, or a phone's
## Mobile Hotspot. It does not use broadcast: iOS blocks UDP broadcast and
## multicast for apps without a restricted Apple entitlement, and Android drops
## them unless the app holds a multicast lock. Instead, the guest sends a tiny
## unicast probe to every address in its own /24 about once a second, and hosts
## answer with their name and game port. Only names, IPs and ports cross the
## network; nothing camera-related.
##
## Owned by main.gd, which calls poll() every frame.

signal hosts_changed

const DISCOVERY_PORT := 27046
const PROBE := "PUB1?"
const REPLY_TAG := "PUB1"
const PROBE_INTERVAL := 1.0
## A host that has not answered for this long is dropped from the list.
const HOST_TTL := 3.5
const MAX_NAME := 16
## Cellular, VPN and virtual interfaces: never swept or shown. Carrier networks
## often hand out private 10.x addresses that would otherwise look like Wi-Fi.
const SKIP_INTERFACE_PREFIXES := [
	"rmnet", "ccmni", "pdp_ip", "v4-", "tun", "utun", "ipsec", "dummy", "awdl",
	"llw", "veth", "docker", "vethernet", "virtualbox", "vmware", "bluetooth",
]
## Interfaces a phone uses for its own hotspot (Android softAP, iPhone Personal Hotspot).
const HOTSPOT_INTERFACE_PREFIXES := ["ap", "swlan", "softap", "bridge"]

## Found hosts: ip -> {"name": String, "port": int, "seen": float}.
var hosts := {}
## Tests: probe only these addresses instead of sweeping the local subnets.
var targets_override := PackedStringArray()
var advertised_name := ""
var game_port := 0

var _host_socket: PacketPeerUDP
var _browse_socket: PacketPeerUDP
var _clock := 0.0
var _probe_timer := 0.0

func is_advertising() -> bool:
	return _host_socket != null

func is_browsing() -> bool:
	return _browse_socket != null

# --- Host side -------------------------------------------------------------------

## Answers probes on DISCOVERY_PORT until stop_advertising().
func start_advertising(host_name: String, port: int, bind_ip := "*") -> Error:
	stop_advertising()
	advertised_name = clean_name(host_name)
	game_port = port
	var socket := PacketPeerUDP.new()
	var error := socket.bind(DISCOVERY_PORT, bind_ip)
	if error != OK:
		return error
	_host_socket = socket
	return OK

func stop_advertising() -> void:
	if _host_socket != null:
		_host_socket.close()
		_host_socket = null

# --- Guest side ------------------------------------------------------------------

## Probes the local network every PROBE_INTERVAL and keeps `hosts` current.
func start_browsing() -> Error:
	stop_browsing()
	var socket := PacketPeerUDP.new()
	var error := socket.bind(0)
	if error != OK:
		return error
	_browse_socket = socket
	_probe_timer = PROBE_INTERVAL  # Probe on the very next poll.
	return OK

func stop_browsing() -> void:
	if _browse_socket != null:
		_browse_socket.close()
		_browse_socket = null
	if not hosts.is_empty():
		hosts.clear()
		hosts_changed.emit()

# --- Both ------------------------------------------------------------------------

func poll(delta: float) -> void:
	_clock += delta
	if _host_socket != null:
		_answer_probes()
	if _browse_socket != null:
		_probe_timer += delta
		if _probe_timer >= PROBE_INTERVAL:
			_probe_timer = 0.0
			_send_probes()
		_read_replies()
		_expire_hosts()

func _answer_probes() -> void:
	while _host_socket.get_available_packet_count() > 0:
		var packet := _host_socket.get_packet()
		var ip := _host_socket.get_packet_ip()
		var port := _host_socket.get_packet_port()
		if ip.is_empty() or packet.get_string_from_utf8() != PROBE:
			continue
		var reply := JSON.stringify({"g": REPLY_TAG, "name": advertised_name, "port": game_port})
		_host_socket.set_dest_address(ip, port)
		_host_socket.put_packet(reply.to_utf8_buffer())

func _send_probes() -> void:
	var targets := targets_override
	if targets.is_empty():
		targets = sweep_targets(usable_ipv4_addresses(IP.get_local_interfaces()))
	var probe := PROBE.to_utf8_buffer()
	for ip in targets:
		_browse_socket.set_dest_address(ip, DISCOVERY_PORT)
		_browse_socket.put_packet(probe)

func _read_replies() -> void:
	var changed := false
	while _browse_socket.get_available_packet_count() > 0:
		var packet := _browse_socket.get_packet()
		var ip := _browse_socket.get_packet_ip()
		var json := JSON.new()
		if ip.is_empty() or json.parse(packet.get_string_from_utf8()) != OK:
			continue
		var data = json.data
		if not (data is Dictionary) or data.get("g") != REPLY_TAG:
			continue
		var port := int(data.get("port", 0))
		if port <= 0 or port > 65535:
			continue
		var host_name := clean_name(str(data.get("name", "")))
		if host_name.is_empty():
			host_name = "Push-Up Battle"
		var known: Dictionary = hosts.get(ip, {})
		if known.is_empty() or known.name != host_name or known.port != port:
			changed = true
		hosts[ip] = {"name": host_name, "port": port, "seen": _clock}
	if changed:
		hosts_changed.emit()

func _expire_hosts() -> void:
	var stale: Array = []
	for ip in hosts:
		if _clock - float(hosts[ip].seen) > HOST_TTL:
			stale.append(ip)
	for ip in stale:
		hosts.erase(ip)
	if not stale.is_empty():
		hosts_changed.emit()

# --- Helpers (static, unit-tested) ---------------------------------------------------

## Printable characters only, trimmed to MAX_NAME.
static func clean_name(raw: String) -> String:
	var out := ""
	for i in raw.length():
		if raw.unicode_at(i) >= 32 and raw.unicode_at(i) != 127:
			out += raw[i]
	return out.strip_edges().left(MAX_NAME).strip_edges()

static func is_private_ipv4(address: String) -> bool:
	if ":" in address or not address.is_valid_ip_address():
		return false
	if address.begins_with("192.168.") or address.begins_with("10."):
		return true
	if address.begins_with("172."):
		var second := address.split(".")[1].to_int()
		return second >= 16 and second <= 31
	return false

static func _interface_skipped(interface: Dictionary) -> bool:
	for field in [interface.get("name", ""), interface.get("friendly", "")]:
		var lowered := str(field).to_lower()
		for prefix in SKIP_INTERFACE_PREFIXES:
			if lowered.begins_with(prefix):
				return true
	return false

## Private IPv4 addresses this device is reachable at on Wi-Fi or its hotspot.
## [param interfaces] is IP.get_local_interfaces().
static func usable_ipv4_addresses(interfaces: Array) -> PackedStringArray:
	var found := PackedStringArray()
	for interface: Dictionary in interfaces:
		if _interface_skipped(interface):
			continue
		for address in interface.get("addresses", []):
			if is_private_ipv4(str(address)) and not found.has(str(address)):
				found.append(str(address))
	return found

## Every other address in each of [param own]'s /24 subnets (x.y.z.1-254).
static func sweep_targets(own: PackedStringArray) -> PackedStringArray:
	var targets := PackedStringArray()
	var seen := {}
	for address in own:
		seen[address] = true
	for address in own:
		var parts := address.split(".")
		if parts.size() != 4:
			continue
		var prefix := "%s.%s.%s." % [parts[0], parts[1], parts[2]]
		for i in range(1, 255):
			var ip := prefix + str(i)
			if not seen.has(ip):
				seen[ip] = true
				targets.append(ip)
	return targets

## [{address, hotspot}] for the host's waiting page. A phone sharing its hotspot
## is the gateway, so its address usually ends in .1 (and the interface is often
## named ap0/swlan0/bridge100).
static func describe_networks(interfaces: Array) -> Array:
	var networks: Array = []
	for interface: Dictionary in interfaces:
		if _interface_skipped(interface):
			continue
		var lowered := str(interface.get("name", "")).to_lower()
		var named_hotspot := false
		for prefix in HOTSPOT_INTERFACE_PREFIXES:
			if lowered.begins_with(prefix):
				named_hotspot = true
		for address in interface.get("addresses", []):
			if is_private_ipv4(str(address)):
				networks.append({"address": str(address), "hotspot": named_hotspot or str(address).ends_with(".1")})
	return networks

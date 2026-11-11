extends SceneTree

## Headless checks for nearby-match discovery. Run with:
##   godot --headless --path . --script res://tests/test_lan_discovery.gd
## Exits with code 1 if any check fails.

const Discovery := preload("res://scripts/lan_discovery.gd")

var _failures := 0

func _initialize() -> void:
	_test_interface_filter()
	_test_sweep_targets()
	_test_names()
	_test_networks()
	await _test_loopback_discovery()
	print("\n%s" % ("ALL TESTS PASSED" if _failures == 0 else "%d CHECK(S) FAILED" % _failures))
	quit(1 if _failures > 0 else 0)

func _check(name: String, actual, expected) -> void:
	if actual == expected:
		print("PASS  %s" % name)
	else:
		_failures += 1
		print("FAIL  %s: expected %s, got %s" % [name, expected, actual])

func _iface(name: String, addresses: Array, friendly := "") -> Dictionary:
	return {"name": name, "friendly": friendly, "index": "0", "addresses": addresses}

func _test_interface_filter() -> void:
	var interfaces := [
		_iface("wlan0", ["192.168.1.23", "fe80::1"]),
		_iface("ap0", ["192.168.43.1"]),
		_iface("en0", ["10.0.0.7"]),
		_iface("bridge100", ["172.20.10.1"]),
		_iface("rmnet_data0", ["10.84.2.9"]),
		_iface("lo", ["127.0.0.1"]),
		_iface("{GUID}", ["172.24.160.1"], "vEthernet (WSL)"),
		_iface("wlan1", ["100.64.3.2"]),
	]
	var found := Discovery.usable_ipv4_addresses(interfaces)
	_check("keeps Wi-Fi and hotspot addresses", found, PackedStringArray(["192.168.1.23", "192.168.43.1", "10.0.0.7", "172.20.10.1"]))

func _test_sweep_targets() -> void:
	var targets := Discovery.sweep_targets(PackedStringArray(["192.168.43.1"]))
	_check("/24 sweep has 253 targets", targets.size(), 253)
	_check("sweep skips own address", targets.has("192.168.43.1"), false)
	_check("sweep covers .254", targets.has("192.168.43.254"), true)
	_check("sweep never hits broadcast .255", targets.has("192.168.43.255"), false)
	var two := Discovery.sweep_targets(PackedStringArray(["192.168.1.5", "192.168.1.9"]))
	_check("two addresses in one /24 don't double up", two.size(), 252)

func _test_names() -> void:
	_check("names are trimmed", Discovery.clean_name("  Christian  "), "Christian")
	_check("control characters removed", Discovery.clean_name("A\nB\tC"), "ABC")
	_check("names capped at 16", Discovery.clean_name("abcdefghijklmnopqrstuvwxyz").length(), 16)

func _test_networks() -> void:
	var networks := Discovery.describe_networks([_iface("wlan0", ["192.168.1.23"]), _iface("wlan2", ["192.168.77.1"]), _iface("ap0", ["10.20.30.40"])])
	_check("client Wi-Fi is not a hotspot", networks[0].hotspot, false)
	_check(".1 gateway address is a hotspot", networks[1].hotspot, true)
	_check("ap0 interface is a hotspot", networks[2].hotspot, true)

func _test_loopback_discovery() -> void:
	var host := Discovery.new()
	var guest := Discovery.new()
	guest.targets_override = PackedStringArray(["127.0.0.1"])
	_check("host starts advertising", host.start_advertising("Tester\n", 27045, "127.0.0.1"), OK)
	_check("guest starts browsing", guest.start_browsing(), OK)
	var changes := [0]
	guest.hosts_changed.connect(func(): changes[0] += 1)
	var found := await _poll_until(host, guest, func(): return guest.hosts.has("127.0.0.1"), 3.0)
	_check("guest finds the host", found, true)
	if found:
		_check("host name and port", [guest.hosts["127.0.0.1"].name, guest.hosts["127.0.0.1"].port], ["Tester", 27045])
	host.stop_advertising()
	var gone := await _poll_until(host, guest, func(): return guest.hosts.is_empty(), Discovery.HOST_TTL + 2.0)
	_check("host disappears after it stops", gone, true)
	_check("list changed when found and when lost", changes[0], 2)
	guest.stop_browsing()

func _poll_until(host: RefCounted, guest: RefCounted, condition: Callable, timeout: float) -> bool:
	var start := Time.get_ticks_msec()
	var last := start
	while not condition.call():
		var now := Time.get_ticks_msec()
		if now - start > timeout * 1000.0:
			return false
		var delta := (now - last) / 1000.0
		last = now
		host.poll(delta)
		guest.poll(delta)
		await process_frame
	return true

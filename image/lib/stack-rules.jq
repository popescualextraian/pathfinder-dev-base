# The stack rules on compose's normalised model (docker compose config --format json): one line per
# break, "<kind> <name>: <what>". Services reach nothing of the host: no privileges, host namespaces,
# host paths or the Docker socket, and ports only as a random loopback port.
def nonempty(k): (.[k] // null) as $v | $v != null and $v != "" and $v != [] and $v != {} and $v != false;

def service_breaks:
  . as $s
  | (["privileged", "cap_add", "devices", "device_cgroup_rules", "network_mode", "pid", "ipc", "uts",
      "userns_mode", "cgroup", "cgroup_parent", "volumes_from", "container_name", "build", "env_file"][]
      | select(. as $k | $s | nonempty($k))),
    (select(any(($s.security_opt // [])[]; test("unconfined"))) | "security_opt unconfined"),
    (select(any(($s.volumes // [])[]; .type == "bind" or .type == "npipe")) | "a bind mount"),
    (select(any(($s.volumes // [])[]; (.source // "") | test("docker\\.sock"))) | "the Docker socket"),
    (select(any(($s.ports // [])[]; .host_ip != "127.0.0.1" or ((.published // "") | tostring) != ""))
      | "ports other than a random loopback port (127.0.0.1::PORT)");

(.services // {} | to_entries[] | .key as $n | .value | service_breaks | "service \($n): \(.)"),
(.volumes // {} | to_entries[] | select(.value | nonempty("external") or nonempty("driver_opts") or ((.driver // "local") != "local"))
  | "volume \(.key): external, or with driver options or a driver other than local"),
(.networks // {} | to_entries[] | select(.value | nonempty("external") or ((.driver // "bridge") != "bridge"))
  | "network \(.key): external or not a bridge"),
(.configs // {} | to_entries[] | select(.value | nonempty("file")) | "config \(.key): from a file"),
(.secrets // {} | to_entries[] | select(.value | nonempty("file")) | "secret \(.key): from a file")

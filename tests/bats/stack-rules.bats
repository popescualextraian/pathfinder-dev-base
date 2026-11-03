#!/usr/bin/env bats
# The stack rules (image/lib/stack-rules.jq) on compose's normalised model: one line per break.
load helpers

setup() { RULES="$REPO_ROOT/image/lib/stack-rules.jq"; }

check() { jq -r -f "$RULES" <<<"$1"; }
svc() { printf '{"services":{"db":%s}}' "$1"; }

@test "a plain service with named volumes, env and a random loopback port passes" {
  run check '{"services":{"db":{"image":"postgres:17","environment":{"P":"x"},
    "volumes":[{"type":"volume","source":"d","target":"/data"},{"type":"tmpfs","target":"/tmp"}],
    "ports":[{"host_ip":"127.0.0.1","target":5432,"mode":"ingress","protocol":"tcp"}]}},
    "volumes":{"d":{"name":"x_d"}},"networks":{"default":{"name":"x_default"}}}'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "each way to the host is refused, naming the service" {
  for s in '{"privileged":true}' '{"cap_add":["NET_ADMIN"]}' '{"devices":["/dev/sda"]}' \
           '{"security_opt":["seccomp=unconfined"]}' '{"network_mode":"host"}' '{"pid":"host"}' \
           '{"ipc":"host"}' '{"userns_mode":"host"}' '{"cgroup_parent":"x"}' '{"volumes_from":["other"]}' \
           '{"volumes":[{"type":"bind","source":"/","target":"/host"}]}' \
           '{"volumes":[{"type":"volume","source":"/var/run/docker.sock","target":"/s"}]}' \
           '{"container_name":"db"}' '{"build":{"context":"."}}' '{"env_file":[{"path":"a"}]}'; do
    run check "$(svc "$s")"
    [[ "$output" == "service db: "* ]] || { echo "not refused: $s"; return 1; }
  done
}

@test "ports are allowed only as a random loopback port" {
  run check "$(svc '{"ports":[{"host_ip":"127.0.0.1","target":5432,"published":"5432"}]}')"
  [[ "$output" == *"service db: ports"* ]]
  run check "$(svc '{"ports":[{"target":5432}]}')"
  [[ "$output" == *"service db: ports"* ]]
  run check "$(svc '{"ports":[{"host_ip":"0.0.0.0","target":5432}]}')"
  [[ "$output" == *"service db: ports"* ]]
}

@test "external or host-backed volumes and networks, and file configs and secrets are refused" {
  run check '{"services":{},"volumes":{"d":{"external":true}}}'
  [[ "$output" == "volume d: "* ]]
  run check '{"services":{},"volumes":{"d":{"driver_opts":{"type":"none","o":"bind","device":"/"}}}}'
  [[ "$output" == "volume d: "* ]]
  run check '{"services":{},"volumes":{"d":{"driver":"local"}}}'
  [ -z "$output" ]
  run check '{"services":{},"networks":{"n":{"external":true}}}'
  [[ "$output" == "network n: "* ]]
  run check '{"services":{},"networks":{"n":{"driver":"host"}}}'
  [[ "$output" == "network n: "* ]]
  run check '{"services":{},"configs":{"c":{"file":"/etc/passwd"}}}'
  [[ "$output" == "config c: "* ]]
  run check '{"services":{},"secrets":{"s":{"file":"/root/x"}}}'
  [[ "$output" == "secret s: "* ]]
}

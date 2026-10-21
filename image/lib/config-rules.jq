# semantic_errs: cross-field rules; run only on a schema-valid config.
def semantic_errs:
  . as $c
  | [ (["java", 21], ["node", 22]) as [$t, $base]
      | ($c.tools[$t] // false) | select(type == "object") | . as $o
      | select($o.default != $base and (($o.versions | index($o.default)) == null))
      | ".tools.\($t).default: \($o.default) is not in versions" ];

# secret_errs: a literal value under a key that names a token, password or secret.
def secret_errs:
  [ paths(type == "string") as $p
    | select($p[-1] | tostring | ascii_downcase | test("token|password|secret"))
    | getpath($p) as $val
    | select($val != "" and ($val | test("^\\$\\{[A-Za-z_][A-Za-z0-9_]*\\}$") | not))
    | "." + ($p | map(tostring) | join(".")) + ": literal secret; reference it as ${VAR} and put the value in .agentic/.env" ];

# apps_errs: app names, port range, the bridge's port, a port used by two apps, env keys and env_files paths.
# Values of the wrong type are left to the schema check.
def apps_errs:
  (if (.apps | type) == "object" then .apps else {} end
   | with_entries(select(.value | type == "object"))
   | map_values(.ports |= (if type == "array" then map(select(type == "number")) else [] end))) as $a
  | def bad_rel: startswith("/") or test("(^|/)\\.\\.(/|$)");
    [ $a | to_entries[] | .key as $n | .value as $v
      | (if ($n | test("^[a-z][a-z0-9-]{0,30}$")) then empty
         else ".apps.\($n): app name must match ^[a-z][a-z0-9-]{0,30}$" end),
        ( $v.ports | to_entries[] | select(.value < 1 or .value > 65535)
          | ".apps.\($n).ports[\(.key)]: port \(.value) is out of range"),
        ( $v.ports | to_entries[] | select(.value == 8765)
          | ".apps.\($n).ports[\(.key)]: port 8765 is the bridge's"),
        ( $v.dir // empty | strings | select(bad_rel)
          | ".apps.\($n).dir: must be a relative path inside the checkout"),
        ( $v.env // {} | objects | keys[]
          | select(test("^[A-Z_][A-Z0-9_]*$") | not)
          | ".apps.\($n).env.\(.): env keys must match ^[A-Z_][A-Z0-9_]*$"),
        ( $v.env // {} | objects | keys[] | select(test("TOKEN|KEY|SECRET|PASSWORD"; "i"))
          | ".apps.\($n).env.\(.): a key naming a token, key, secret or password is refused; put the value in .agentic/.env"),
        ( $v.env_files // [] | arrays | to_entries[] | select(.value | type == "object") | .key as $i | .value
          | (to_entries[] | select((.key == "from" or .key == "to") and (.value | type == "string") and (.value | bad_rel))
             | ".apps.\($n).env_files[\($i)].\(.key): must be a relative path without ..") ) ]
  + [ [ $a | to_entries[] | .key as $n | .value.ports[] | {port: ., app: $n} ]
      | group_by(.port)[] | select(length > 1)
      | ".apps: port \(.[0].port) is used by \(map(.app) | unique | join(", "))" ];

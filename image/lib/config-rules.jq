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

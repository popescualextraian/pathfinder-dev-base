# errs(schema; path): every violation of schema by ., as "path: message" strings.
def tname: if type == "number" then (if . == floor then "integer" else "number" end) else type end;
def typeok($t): tname as $n | ($t | if type == "array" then . else [.] end)
  | any(.[]; . == $n or (. == "number" and $n == "integer"));
def tlabel($t): $t | if type == "array" then join(" or ") else . end;
def errs($s; $p):
  . as $v
  | if ($s | has("type")) and ($v | typeok($s.type) | not) then
      ["\($p): expected \(tlabel($s.type)), got \($v | tname)"]
    else
      (if ($s | has("enum")) and (($s.enum | index([$v])) == null)
         then ["\($p): must be one of \($s.enum | map(tojson) | join(", "))"] else [] end)
      + (if ($s | has("pattern")) and ($v | type) == "string" and (($v | test($s.pattern)) | not)
           then ["\($p): does not match \($s.pattern)"] else [] end)
      + (if ($s | has("minLength")) and ($v | type) == "string" and ($v | length) < $s.minLength
           then ["\($p): must not be empty"] else [] end)
      + (if ($s | has("minimum")) and ($v | type) == "number" and $v < $s.minimum
           then ["\($p): must be at least \($s.minimum)"] else [] end)
      + (if ($s | has("maxItems")) and ($v | type) == "array" and ($v | length) > $s.maxItems
           then ["\($p): at most \($s.maxItems) items"] else [] end)
      + (if ($s | has("maxProperties")) and ($v | type) == "object" and ($v | length) > $s.maxProperties
           then ["\($p): at most \($s.maxProperties) entries"] else [] end)
      + (if ($v | type) == "object" then
           [ ($s.required // [])[] as $r | select(($v | has($r)) | not) | "\($p).\($r): is required" ]
           + [ $v | to_entries[] | .key as $k | .value as $x
               | if (($s.properties // {}) | has($k)) then ($x | errs($s.properties[$k]; "\($p).\($k)"))[]
                 elif $s.additionalProperties == false then "\($p).\($k): unknown key"
                 elif ($s.additionalProperties | type) == "object" then ($x | errs($s.additionalProperties; "\($p).\($k)"))[]
                 else empty end ]
         else [] end)
      + (if ($v | type) == "array" and ($s | has("items")) then
           [ range(0; $v | length) as $i | ($v[$i] | errs($s.items; "\($p)[\($i)]"))[] ]
         else [] end)
      + (if ($s | has("anyOf")) then
           ([ $s.anyOf[] as $alt | ($v | errs($alt; $p)) ]) as $alts
           | if any($alts[]; length == 0) then [] else ["\($p): matches none of the allowed forms"] end
         else [] end)
    end;

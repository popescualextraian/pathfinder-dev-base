# Seed merge (docs/specs/2026-10-14-revamp-design.md section 6.1).

# delta($base): the parts of . that differ from $base; objects are compared key by key.
def delta($base):
  if type == "object" and ($base | type) == "object" then
    . as $o
    | reduce keys[] as $k ({};
        if ($base | has($k)) | not then .[$k] = $o[$k]
        elif $o[$k] == $base[$k] then .
        else .[$k] = ($o[$k] | delta($base[$k])) end)
  else . end;

# drop($keys): . without the top-level keys in $keys.
def drop($keys): reduce $keys[] as $k (.; del(.[$k]));

# seedmerge($old; $new): the home (.) with the new seed applied. $new's values are set; values
# only $old had are removed unless the user changed them, key by key inside objects; everything
# else is left alone.
def seedmerge($old; $new):
  if ($new | type) == "object" and type == "object" then
    reduce ((($old | objects | keys) // []) + ($new | keys) | unique[]) as $k (.;
      ($old | if type == "object" then .[$k] else null end) as $ok
      | if ($new | has($k)) then .[$k] = (.[$k] | seedmerge($ok; $new[$k]))
        elif has($k) and .[$k] == $ok then del(.[$k])
        elif has($k) and (.[$k] | type) == "object" and ($ok | type) == "object" then
          # the user changed something inside: remove only the seed's own keys
          (.[$k] | seedmerge($ok; {})) as $rest
          | if $rest == {} then del(.[$k]) else .[$k] = $rest end
        else . end)
  else $new end;

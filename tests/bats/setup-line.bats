#!/usr/bin/env bats
load helpers

setup() {
  make_tmp_home
  make_agentic_dir
  source "$AGENTIC_DIR/lib/common.sh"
  source "$AGENTIC_DIR/lib/setup-line.sh"
}

@test "words stay literal: quotes group, nothing is expanded" {
  line_words "add mcp x --env 'A=b c' -- run ~/x \$HOME '*' \"d e\""
  [ "${#WORDS[@]}" -eq 11 ]
  [ "${WORDS[4]}" = "A=b c" ]
  [ "${WORDS[7]}" = "~/x" ]
  [ "${WORDS[8]}" = '$HOME' ]
  [ "${WORDS[9]}" = '*' ]
  [ "${WORDS[10]}" = "d e" ]
}

@test "unbalanced quotes fail" {
  run parse_line "add plugin 'x@m"
  [ "$status" -eq 1 ]
}

@test "add plugin: build phase, key is the id, target kept" {
  parse_line "add plugin superpowers@claude-plugins-official --target claude"
  [ "$L_KIND" = plugin ]
  [ "$L_PHASE" = build ]
  [ "$L_KEY" = superpowers@claude-plugins-official ]
  [ "$L_TARGETS" = claude ]
}

@test "add plugin without a marketplace is refused" {
  if parse_line "add plugin superpowers"; then return 1; fi
  [[ "$L_ERR" == *"NAME@MARKETPLACE"* ]]
}

@test "add marketplace takes any source" {
  parse_line "add marketplace obra/superpowers-marketplace --target copilot"
  [ "$L_KIND" = marketplace ]
  [ "$L_KEY" = obra/superpowers-marketplace ]
  [ "$L_TARGETS" = copilot ]
}

@test "add mcp stdio: env names and literals, command after --" {
  parse_line "add mcp jira --env JIRA_PERSONAL_TOKEN --env JIRA_URL=https://jira.example.com -- mcp-atlassian --verbose"
  [ "$L_KIND" = mcp ]
  [ "$L_KEY" = jira ]
  [ "${L_ENV[*]}" = "JIRA_PERSONAL_TOKEN JIRA_URL=https://jira.example.com" ]
  [ "${L_CMD[*]}" = "mcp-atlassian --verbose" ]
}

@test "add mcp http needs a URL and no command" {
  parse_line "add mcp docs --transport http https://mcp.example.com/mcp"
  [ "$L_TRANSPORT" = http ]
  [ "$L_URL" = https://mcp.example.com/mcp ]
  if parse_line "add mcp docs --transport http"; then return 1; fi
  if parse_line "add mcp docs"; then return 1; fi
  if parse_line "add mcp docs --transport ftp x"; then return 1; fi
}

@test "an env name must be a variable name" {
  if parse_line "add mcp x --env 9X -- y"; then return 1; fi
}

@test "copy: build phase, key is DEST, source relative and inside .agentic" {
  parse_line "copy files/settings.xml /home/dev/.m2/settings.xml"
  [ "$L_KIND" = copy ]
  [ "$L_KEY" = /home/dev/.m2/settings.xml ]
  [ "$L_SRC" = files/settings.xml ]
  if parse_line "copy /etc/passwd /x"; then return 1; fi
  if parse_line "copy ../x /x"; then return 1; fi
  if parse_line "copy files/x relative/dest"; then return 1; fi
}

@test "copy of a secret-looking file warns" {
  parse_line "copy files/id_rsa /home/dev/.ssh/id_rsa"
  [[ "$L_WARN" == *"looks like a secret"* ]]
  parse_line "copy files/corp.crt /usr/local/share/ca-certificates/corp.crt"
  [ -z "$L_WARN" ]
}

@test "add skill/agent/command: path under its folder" {
  parse_line "add agent agents/db.md --target claude"
  [ "$L_KIND" = agent ]
  [ "$L_KEY" = agents/db.md ]
  parse_line "add skill skills/review/"
  [ "$L_KEY" = skills/review ]
  if parse_line "add agent skills/x"; then return 1; fi
}

@test "add workspace: URL or path, name from the URL" {
  parse_line "add workspace https://github.com/example/api.git --ref main"
  [ "$L_KIND" = workspace ]
  [ "$L_PHASE" = start ]
  [ "$L_KEY" = api ]
  [ "$L_OPT" = url ]
  [ "$L_REF" = main ]
  parse_line "add workspace git@github.com:example/web.git"
  [ "$L_KEY" = web ]
  [ "$L_OPT" = url ]
  parse_line "add workspace ../shared-lib --name lib"
  [ "$L_KEY" = lib ]
  [ "$L_OPT" = path ]
  if parse_line "add workspace ../x --ref main"; then return 1; fi
}

@test "mount and volume: run phase, absolute DEST without : or ," {
  parse_line "mount ~/.aws /home/dev/.aws --readonly"
  [ "$L_KIND" = mount ]
  [ "$L_PHASE" = run ]
  [ "$L_SRC" = "~/.aws" ]
  [ "$L_OPT" = ro ]
  [ "$L_KEY" = /home/dev/.aws ]
  parse_line "volume m2 /home/dev/.m2"
  [ "$L_KIND" = volume ]
  [ "$L_KEY" = m2 ]
  [ "$L_DEST" = /home/dev/.m2 ]
  if parse_line "mount a:b /x"; then return 1; fi
  if parse_line "volume M2 /x"; then return 1; fi
  if parse_line "volume m2 x"; then return 1; fi
}

@test "options are only accepted where they belong" {
  if parse_line "copy files/a /a --target claude"; then return 1; fi
  if parse_line "volume m2 /m2 --readonly"; then return 1; fi
  if parse_line "add plugin a@b --env X"; then return 1; fi
  if parse_line "add plugin a@b --target codex"; then return 1; fi
  if parse_line "add plugin a@b extra"; then return 1; fi
  if parse_line "frobnicate x"; then return 1; fi
}

@test "line_ident: targets normalised, default used when none given" {
  parse_line "add plugin a@b --target copilot,claude"
  [ "$(line_ident claude,copilot)" = $'plugin\ta@b\tclaude,copilot' ]
  parse_line "add plugin a@b"
  [ "$(line_ident copilot)" = $'plugin\ta@b\tcopilot' ]
  parse_line "volume m2 /m2"
  [ "$(line_ident claude)" = $'volume\tm2\t' ]
}

@test "setup_errs reports bad and duplicate lines by index" {
  jq -n '{targets: ["claude","copilot"], setup: ["add plugin a@b", "frob", "add plugin a@b --target claude,copilot"]}' > "$BATS_TEST_TMPDIR/c.json"
  run setup_errs "$BATS_TEST_TMPDIR/c.json"
  [[ "$output" == *".setup[1]: unknown command"* ]]
  [[ "$output" == *".setup[2]: same command, key and targets as .setup[0]"* ]]
}

@test "a literal value under a token, password or secret name is refused; a reference is fine" {
  if parse_line "add mcp docs --env API_TOKEN=abc123 -- run"; then return 1; fi
  [[ "$L_ERR" == *"--env API_TOKEN: literal secret; write --env API_TOKEN and put the value in .agentic/.env"* ]]
  parse_line "add mcp docs --env API_TOKEN -- run"
  parse_line "add mcp docs --env DB_URL=https://db.example.com -- run"
}

@test "literal --env values under common secret names are refused; ordinary names pass" {
  for e in OPENAI_API_KEY=sk-1 JIRA_PAT=x AUTH=x GH_CREDENTIALS=x DB_PASS=x APIKEY=x; do
    if parse_line "add mcp x --env $e -- run"; then echo "accepted: $e"; return 1; fi
  done
  parse_line "add mcp x --env PATH=/usr/bin --env KEYBOARD=us --env JIRA_URL=https://jira.example.com -- run"
}

@test "credentials in a URL are refused anywhere in the line" {
  for l in "add workspace https://user:tok@example.com/x.git" "add marketplace https://u:p@example.com/m.git" \
           "add mcp x --transport http https://h.example.com/mcp?token=abc" "add mcp x -- run --url https://u:p@h.example.com"; do
    if parse_line "$l"; then echo "accepted: $l"; return 1; fi
    [[ "$L_ERR" == *"credentials in a URL"* ]]
  done
  parse_line "add workspace https://example.com/x.git"
  parse_line "add workspace git@example.com:team/x.git"
}

@test "add mcp refuses --env on a remote server, which would drop it" {
  if parse_line "add mcp docs --env K --transport http https://mcp.example.com/mcp"; then return 1; fi
  [[ "$L_ERR" == *"--env"* ]]
}

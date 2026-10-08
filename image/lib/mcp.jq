# desired($graphify): managed MCP servers from the resolved config, in Claude's format.
def desired($graphify):
  (if .mcp.atlassian.enabled then
     {atlassian: {type: "stdio", command: "mcp-atlassian", env: {},
       args: ([if (.mcp.atlassian.jira_url // "") != "" then "--jira-url", .mcp.atlassian.jira_url else empty end]
            + [if (.mcp.atlassian.confluence_url // "") != "" then "--confluence-url", .mcp.atlassian.confluence_url else empty end])}}
   else {} end)
  + (if .mcp.playwright.enabled then
       {playwright: {type: "stdio", command: "mcp-server-playwright", env: {},
         args: ((if .mcp.playwright.mode == "headless" then ["--headless"] else [] end)
                + ["--browser", "chromium", "--no-sandbox", "--output-dir", "/tmp/playwright-mcp"])}}
     else {} end)
  + (if .mcp.graphify.enabled then
       {graphify: {type: "stdio", command: $graphify, env: {},
         args: ["-m", "graphify.serve", "graphify-out/graph.json"]}}
     else {} end)
  + ([ (.mcp.custom // [])[]
       | {(.name): (if .type == "stdio"
                     then {type: "stdio", command, args: (.args // []), env: (.env // {})}
                     else {type: "http", url, headers: (.headers // {})} end)} ] | add // {});

# to_copilot: Claude-format servers in Copilot CLI's mcp-config format.
def to_copilot:
  with_entries(.value |= (if .type == "stdio"
    then {type: "local", command, args, env, tools: ["*"]}
    else {type: "http", url, headers, tools: ["*"]} end));

# merge_managed($managed; $desired): drop previously managed names, then add the desired ones.
def merge_managed($managed; $desired):
  .mcpServers = (((.mcpServers // {}) | with_entries(select(.key as $k | ($managed | index($k)) == null))) + $desired);

# env_refs: names referenced as ${NAME} in any string.
def env_refs: [.. | strings | scan("\\$\\{([A-Za-z_][A-Za-z0-9_]*)\\}")[0]] | unique;

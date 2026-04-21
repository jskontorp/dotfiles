# pi-notion-routing.zsh — route @feniix/pi-notion auth by cwd at pi launch.
#
# Why this lives in shell and not in the extension:
#   @feniix/pi-notion captures NOTION_MCP_AUTH_FILE once at module load
#   (FileTokenStorage constructor). Setting the env var from a tool_call
#   handler has no effect. So routing happens here, before pi starts.
#
# Behaviour:
#   - cwd under /code/personal/  → NOTION_MCP_AUTH_FILE=~/.pi/agent/notion-mcp-auth-personal.json
#   - cwd contains a volve path segment → NOTION_MCP_AUTH_FILE=~/.pi/agent/notion-mcp-auth-volve.json
#   - anything else → NOTION_MCP_AUTH_FILE is not set by this wrapper. If the
#     parent shell already exported one, it's inherited; otherwise @feniix
#     falls back to its default ~/.pi/agent/notion-mcp-auth.json.
#
# One-time setup per machine:
#   1. cd into a Volve repo, run `pi`, issue `/notion`, OAuth as Volve.
#      The token lands at the volve-specific path because this function
#      set NOTION_MCP_AUTH_FILE for you.
#   2. Optional: cd to ~/code/personal/<any>, repeat for personal.
#   3. On the VM: scp ~/.pi/agent/notion-mcp-auth-*.json vm:~/.pi/agent/ from
#      your mac. OAuth tokens are portable; they don't bind to machine
#      identity. Headless VM can't run browser OAuth directly.
#
# Cross-workspace within one pi session is not supported — cwd at launch
# pins the workspace. Same implicit constraint the Linear setup has.

# Pure helper: cwd → auth file path (empty string if no match).
# Split out so test/verify.sh can test the mapping without execing pi.
# Personal match runs before volve so ~/code/personal/volve-notes routes to
# personal, mirroring linear-routing.ts precedence.
_pi_notion_auth_file() {
	local pwd="${1:-$PWD}"
	case "$pwd" in
		*/code/personal/*)
			echo "$HOME/.pi/agent/notion-mcp-auth-personal.json"
			;;
		*[/_-]volve[/_-]*|*[/_-]volve)
			echo "$HOME/.pi/agent/notion-mcp-auth-volve.json"
			;;
	esac
}

pi() {
	local auth
	auth="$(_pi_notion_auth_file "$PWD")"
	if [[ -n "$auth" ]]; then
		NOTION_MCP_AUTH_FILE="$auth" command pi "$@"
	else
		command pi "$@"
	fi
}

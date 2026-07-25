# API-Billed Agent

Run a prompt through a separate Claude Code process billed to the Anthropic API (pay-as-you-go), enabling features not available on the Pro subscription such as the 1M token context window.

## Usage
/api-agent [options] <prompt or task description>

## Options
- `--1m` : Use the 1M token extended context window (appends `[1m]` to the model)
- `--sp` : Include the custom system prompt from `$env:USERPROFILE\Desktop\claude-config\System Prompt.txt`
- `--spsp` : Include the custom system prompt AND skip all permission prompts
- `--model <name>` : Override the model (default: opus, an alias that always resolves to the current Opus). Combine with `--1m` for extended context.

## Behavior

1. **Retrieve the API key** by running this PowerShell command via Bash:
   ```
   powershell -Command "& { $encrypted = Get-Content \"$env:USERPROFILE\.claude\.api-key.enc\"; $secure = $encrypted | ConvertTo-SecureString; [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)) }"
   ```
   Store the result (the API key) for the next step. Do NOT display it to the user.

2. **Build the claude command** based on the options:
   - Base: `claude -p "<prompt>"`
   - If `--1m`: add `--model opus[1m]` (or `--model <name>[1m]` if `--model` was specified)
   - If `--model` without `--1m`: add `--model <name>`
   - If `--sp` or `--spsp`: add `--append-system-prompt "$(Get-Content "$env:USERPROFILE\Desktop\claude-config\System Prompt.txt" -Raw)"`
   - If `--spsp`: also add `--dangerously-skip-permissions --permission-mode dontAsk`

3. **Execute** the command via Bash with `ANTHROPIC_API_KEY=<key>` set as a prefix environment variable:
   ```
   ANTHROPIC_API_KEY=<key> claude -p "<prompt>" [flags...]
   ```
   Use a generous timeout (up to 600000ms) since API calls with large context may take time.

4. **Return the output** to the user. The API key is only used for this single invocation and is not persisted in the environment.

## Examples
```
/api-agent Summarize the architecture of this codebase
/api-agent --1m Analyze all files in src/ and generate a comprehensive dependency graph
/api-agent --sp --1m Review this entire project for security vulnerabilities
/api-agent --spsp --1m Refactor the authentication module following the patterns in ARCHITECTURE.md
/api-agent --model sonnet --1m Quickly summarize README.md
```

## Notes
- The API key is stored encrypted with Windows DPAPI at `~/.claude/.api-key.enc` and decrypted on-the-fly
- Only the same Windows user account can decrypt the key
- API usage is billed at Anthropic's pay-as-you-go rates (see console.anthropic.com for pricing)
- Extended context (1M) costs ~2x standard per-token rates for input tokens above 200K
- The `-p` (print) flag runs Claude in non-interactive single-shot mode

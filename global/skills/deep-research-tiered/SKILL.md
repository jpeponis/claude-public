---
name: deep-research-tiered
description: Run the tiered deep-research workflow - decompose a question into search angles, fan out parallel search and fetch agents on cheap worker models, verify each extracted claim with a Haiku scan that escalates doubtful ones to adversarial Sonnet votes, then synthesize a cited report and critique its completeness. Use for questions that need multi-source investigation and fact-checking rather than a single search, and whenever the user asks for deep research, a research report, or a thorough investigation of a topic.
---

# Deep Research (tiered)

Runs `deep-research-tiered.js`, a dynamic workflow that orchestrates the whole
investigation deterministically instead of leaving the fan-out to a single agent's
judgment. Every spawned agent uses the lightweight `research-worker` definition — no MCP
tools, no skills — so the worker context stays small across a wide fan-out.

## Usage

```
/deep-research-tiered <question>
```

The question can also be passed as an object to override the worker tiers:
`{ question, workerModel: 'sonnet', scanModel: 'haiku' }`.

## Steps

**1. Enable the Workflow tool.** It is off by default: `"enableWorkflows": false` in
`~/.claude/settings.json` keeps the tool's large schema out of every session's context,
and the Workflow tool is not one of the Tool-Search-deferred built-ins, so this setting
is the only lever. Set it to `true`.

The setting **hot-reloads on every request** — no restart. The schema appears in the next
rebuilt request, so the Workflow tool is callable on your very next step, not this one.

**2. Call the Workflow tool** with `deep-research-tiered` and the user's question.
The script lives at `{{DESKTOP}}/.claude/workflows/deep-research-tiered.js`.

**3. Set `enableWorkflows` back to `false`** once the workflow has launched. The gate is
checked only at launch, so a running workflow is unaffected by the edit, and future
sessions stay lean.

## Phases the workflow runs

| Phase | Model | What happens |
| --- | --- | --- |
| Scope | session | Decompose into search angles and key assertions |
| Search | worker (`sonnet`) | One parallel WebSearch agent per angle |
| Fetch | worker | URL-dedup, fetch top sources, extract falsifiable claims |
| Verify | `haiku`, escalating to `sonnet` | Fast scan vote; doubtful or key claims get 2 diverse-lens votes, and 2 refutations kill a claim |
| Synthesize | session | Merge duplicates, rank by confidence, cite sources |
| Critique | session | Flag unconfirmed key assertions and coverage gaps |

## Alternative: skip the toggle entirely

Launching a session with workflows already on avoids editing settings mid-session:

```powershell
claude --settings "$env:USERPROFILE\.claude\workflows-on.json"
```

That file contains only `{ "enableWorkflows": true }` and overrides nothing else. Prefer
it when you already know the session is a research session.

## Notes

- Restoring the setting in step 3 matters. Leaving it on costs context in every
  subsequent session, and the cost is invisible — nothing reports a schema you are
  carrying but not using.
- The workflow is a Claude Code feature. It does not exist in Cowork or cloud sessions,
  so this skill has nothing to do there.

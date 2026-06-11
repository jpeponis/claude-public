export const meta = {
  name: 'deep-research-tiered',
  description: 'Deep research with tiered worker models (Haiku scan → Sonnet escalation), barebones worker context, adaptive verification, and a completeness critic.',
  whenToUse: 'When the user wants a deep, multi-source, fact-checked research report and wants the investigation fan-out to run on cheaper/faster worker models while the session model handles decomposition + synthesis. Pass the question as args (string), or {question, workerModel, scanModel} to override the worker tiers.',
  phases: [
    {"title":"Scope","detail":"Decompose into angles + key assertions (session model)"},
    {"title":"Search","detail":"Parallel WebSearch agents, one per angle (worker model)"},
    {"title":"Fetch","detail":"URL-dedup, fetch top sources, extract falsifiable claims (worker model)"},
    {"title":"Verify","detail":"Haiku scan vote; escalate doubtful/key claims to 2 Sonnet diverse-lens votes"},
    {"title":"Synthesize","detail":"Merge dupes, rank by confidence, cite sources (session model)"},
    {"title":"Critique","detail":"Flag unconfirmed key assertions + coverage gaps (session model)"}
  ],
}

// deep-research-tiered (redesigned):
//  - Every spawned agent uses the `research-worker` agentType: barebones system prompt
//    (~/.claude/agents/research-worker.md), no MCP tools, no skills, tool-search kept.
//  - search/fetch + verify-escalation run on WORKER_MODEL (default 'sonnet').
//  - the verify FIRST-PASS scan runs on SCAN_MODEL (default 'haiku') — fast/cheap triage.
//  - Scope + Synthesize + Critique omit `model` → inherit the session/orchestrator model.
// args: '<question>'  OR  { question, workerModel:'sonnet', scanModel:'haiku' }

const WORKER_AGENT = "research-worker"   // minimal-context subagent definition
const ESCALATED_VOTES = 3                // 1 scan + 2 lenses when a claim is escalated
const REFUTATIONS_REQUIRED = 2           // ≥2 refutations kill an escalated claim
const MAX_FETCH = 15
const MAX_VERIFY_CLAIMS = 25

// ─── Args: string or {question, workerModel, scanModel} ───
const QUESTION = (typeof args === "string" && args.trim())
  || (args && typeof args === "object" && typeof args.question === "string" && args.question.trim())
  || ""
const WORKER_MODEL = (args && typeof args === "object" && args.workerModel) || "sonnet"
const SCAN_MODEL = (args && typeof args === "object" && args.scanModel) || "haiku"

// ─── Schemas ───
const SCOPE_SCHEMA = {
  type: "object", required: ["question", "angles", "summary", "keyAssertions"],
  properties: {
    question: { type: "string" },
    summary: { type: "string" },
    keyAssertions: { type: "array", minItems: 2, maxItems: 6, items: { type: "string" } },
    angles: { type: "array", minItems: 3, maxItems: 6, items: {
      type: "object", required: ["label", "query"],
      properties: {
        label: { type: "string" },
        query: { type: "string" },
        rationale: { type: "string" },
      },
    }},
  },
}
const SEARCH_SCHEMA = {
  type: "object", required: ["results"],
  properties: {
    results: { type: "array", maxItems: 6, items: {
      type: "object", required: ["url", "title", "relevance"],
      properties: {
        url: { type: "string" },
        title: { type: "string" },
        snippet: { type: "string" },
        relevance: { enum: ["high", "medium", "low"] },
      },
    }},
  },
}
const EXTRACT_SCHEMA = {
  type: "object", required: ["claims", "sourceQuality"],
  properties: {
    sourceQuality: { enum: ["primary", "secondary", "blog", "forum", "unreliable"] },
    publishDate: { type: "string" },
    claims: { type: "array", maxItems: 5, items: {
      type: "object", required: ["claim", "quote", "importance"],
      properties: {
        claim: { type: "string" },
        quote: { type: "string" },
        importance: { enum: ["central", "supporting", "tangential"] },
      },
    }},
  },
}
// Lens 1 — fast Haiku triage: support + plausibility + key relevance
const SCAN_SCHEMA = {
  type: "object", required: ["refuted", "confidence", "keyRelevant", "evidence"],
  properties: {
    refuted: { type: "boolean" },
    confidence: { enum: ["high", "medium", "low"] },
    keyRelevant: { type: "boolean" },
    evidence: { type: "string" },
  },
}
// Lenses 2 & 3 — Sonnet escalation
const VERDICT_SCHEMA = {
  type: "object", required: ["refuted", "evidence", "confidence"],
  properties: {
    refuted: { type: "boolean" },
    evidence: { type: "string" },
    confidence: { enum: ["high", "medium", "low"] },
    counterSource: { type: "string" },
  },
}
const REPORT_SCHEMA = {
  type: "object", required: ["summary", "findings", "caveats"],
  properties: {
    summary: { type: "string" },
    findings: { type: "array", items: {
      type: "object", required: ["claim", "confidence", "sources", "evidence"],
      properties: {
        claim: { type: "string" },
        confidence: { enum: ["high", "medium", "low"] },
        sources: { type: "array", items: { type: "string" } },
        evidence: { type: "string" },
        vote: { type: "string" },
      },
    }},
    caveats: { type: "string" },
    openQuestions: { type: "array", items: { type: "string" } },
  },
}
const CRITIC_SCHEMA = {
  type: "object", required: ["unconfirmedKeyAssertions", "gaps", "suggestedFollowups"],
  properties: {
    unconfirmedKeyAssertions: { type: "array", items: { type: "string" } },
    gaps: { type: "string" },
    suggestedFollowups: { type: "array", items: { type: "string" } },
  },
}

// ─── Phase 0: Scope — decompose question + name key assertions (session model) ───
phase("Scope")
if (!QUESTION) {
  return { error: "No research question provided. Pass it as args: Workflow({name: 'deep-research-tiered', args: '<question>'}) or args: {question, workerModel, scanModel}." }
}
log("Models — scan: " + SCAN_MODEL + " · worker: " + WORKER_MODEL + " · scope/synth/critique: session")
const scope = await agent(
  "Decompose this research question into complementary search angles, and name the key assertions the answer hinges on.\n\n" +
  "## Question\n" + QUESTION + "\n\n" +
  "## Task\n" +
  "1. Generate 5 distinct web search queries that together cover the question from different angles. Pick angles that suit the question's domain. Examples:\n" +
  "   - broad/primary  · academic/technical  · recent news  · contrarian/skeptical  · practitioner/implementation\n" +
  "   - For medical: anatomy · common causes · serious differentials · authoritative refs · red flags\n" +
  "   - For tech: state-of-art · benchmarks · limitations · industry adoption · cost/tradeoffs\n" +
  "   Make queries specific enough to surface high-signal results. Avoid redundancy.\n" +
  "2. List 2-5 KEY ASSERTIONS: the specific, falsifiable factual statements the final answer depends on. These deserve the most rigorous verification — phrase each as a checkable claim, not a topic.\n\n" +
  "Return: the question (verbatim or lightly normalized), a 1-2 sentence decomposition strategy, the angles, and the key assertions.\n\nStructured output only.",
  { label: "scope", schema: SCOPE_SCHEMA, agentType: WORKER_AGENT }
)
if (!scope) {
  return { error: "Scope agent returned no result — cannot decompose the research question." }
}
const KEY = Array.isArray(scope.keyAssertions) ? scope.keyAssertions : []
log("Q: " + QUESTION.slice(0, 80) + (QUESTION.length > 80 ? "…" : ""))
log("Angles (" + scope.angles.length + "): " + scope.angles.map(a => a.label).join(", "))
log("Key assertions (" + KEY.length + "): " + KEY.map(k => k.slice(0, 40)).join(" | "))

// ─── Dedup state — accumulates across searchers as they complete ───
const normURL = u => {
  try {
    const p = new URL(u)
    return (p.hostname.replace(/^www\./, "") + p.pathname.replace(/\/$/, "")).toLowerCase()
  } catch { return u.toLowerCase() }
}
const seen = new Map()
const dupes = []
const budgetDropped = []
const relRank = { high: 0, medium: 1, low: 2 }
let fetchSlots = MAX_FETCH

// ─── Prompts ───
const SEARCH_PROMPT = (angle) =>
  "## Web Searcher: " + angle.label + "\n\n" +
  "Research question: \"" + QUESTION + "\"\n\n" +
  "Your angle: **" + angle.label + "** — " + (angle.rationale || "") + "\n" +
  "Search query: `" + angle.query + "`\n\n" +
  "## Task\nUse WebSearch with the query above (or a refined version). Return the top 4-6 most relevant results.\n" +
  "Rank by relevance to the ORIGINAL question, not just the search query. Skip obvious SEO spam/content farms.\n" +
  "Include a short snippet capturing why each result is relevant.\n\nStructured output only."

const FETCH_PROMPT = (source, angle) =>
  "## Source Extractor\n\n" +
  "Research question: \"" + QUESTION + "\"\n\n" +
  "Fetch and extract key claims from this source:\n" +
  "**URL:** " + source.url + "\n**Title:** " + source.title + "\n**Found via:** " + angle + " search\n\n" +
  "## Task\n1. Use WebFetch to retrieve the page content.\n" +
  "2. Assess source quality: primary research/institution? secondary reporting? blog/opinion? forum? unreliable?\n" +
  "3. Extract 2-5 FALSIFIABLE claims that bear on the research question. Each claim must:\n" +
  "   - be a concrete, checkable statement (not vague generalities)\n" +
  "   - include a direct quote from the source as support\n" +
  "   - be rated central/supporting/tangential to the research question\n" +
  "4. Note publish date if available.\n\n" +
  "If the fetch fails or the page is irrelevant/paywalled, return claims: [] and sourceQuality: \"unreliable\".\n\nStructured output only."

// Lens 1 — fast Haiku scan (no web): does the quote support the claim? is it key?
const SCAN_PROMPT = (claim) =>
  "## Claim Scan — fast first-pass (lens 1: quote-support + triage)\n\n" +
  "You are a fast, skeptical scanner. Decide whether this claim needs deeper investigation.\n\n" +
  "## Research question\n" + QUESTION + "\n\n" +
  (KEY.length ? "## Key assertions the report must establish\n" + KEY.map((k, i) => (i + 1) + ". " + k).join("\n") + "\n\n" : "") +
  "## Claim\n\"" + claim.claim + "\"\n" +
  "Source: " + claim.sourceUrl + " (" + claim.sourceQuality + ") · importance: " + claim.importance + "\n" +
  "Supporting quote: \"" + claim.quote + "\"\n\n" +
  "## Decide (judge from the quote and your own knowledge — do NOT web search in this pass)\n" +
  "1. Does the quote actually support the claim, or is it an overreach/misread?\n" +
  "2. Is the claim internally plausible (not obviously marketing fluff or cherry-picked)?\n" +
  "3. keyRelevant: does this claim bear on any listed key assertion above? (false if none are listed)\n\n" +
  "Set refuted=true ONLY if the quote clearly fails to support the claim or it is obviously false.\n" +
  "Set confidence on that judgment; use **low** if you are unsure and a web check would help.\n\nStructured output only. Evidence MUST be specific."

// Lens 2 — Sonnet: actively WebSearch for contradicting evidence
const LENS2_PROMPT = (claim) =>
  "## Adversarial Verifier — Lens 2: contradiction search\n\n" +
  "Be SKEPTICAL. Use WebSearch to find credible evidence that DISPUTES or heavily qualifies this claim.\n\n" +
  "## Research question\n" + QUESTION + "\n\n" +
  "## Claim under review\n\"" + claim.claim + "\"\n" +
  "Source: " + claim.sourceUrl + " (" + claim.sourceQuality + ")\n" +
  "Supporting quote: \"" + claim.quote + "\"\n\n" +
  "## Task\nWebSearch for contradicting or qualifying evidence from credible sources.\n" +
  "refuted=true if a credible source disputes the claim, or no corroboration exists for a strong/extraordinary claim.\n" +
  "refuted=false if the claim is corroborated or uncontested by credible sources.\n" +
  "Cite the strongest counter-source in counterSource. Default to refuted=true if uncertain.\n\nStructured output only. Evidence MUST be specific."

// Lens 3 — Sonnet: source quality + recency
const LENS3_PROMPT = (claim) =>
  "## Adversarial Verifier — Lens 3: source quality & recency\n\n" +
  "## Research question\n" + QUESTION + "\n\n" +
  "## Claim under review\n\"" + claim.claim + "\"\n" +
  "Source: " + claim.sourceUrl + " (" + claim.sourceQuality + ")\n" +
  "Supporting quote: \"" + claim.quote + "\"\n\n" +
  "## Checklist\n" +
  "1. Is the source quality sufficient for the claim's strength? (extraordinary claims need primary sources)\n" +
  "2. Is the claim outdated? Check dates; old claims in fast-moving fields are suspect — WebSearch for a newer figure if useful.\n" +
  "3. Is this a press release / marketing / cherry-picked benchmark / forum speculation?\n\n" +
  "refuted=true if the source is too weak for the claim's strength, outdated, or promotional. refuted=false otherwise.\n" +
  "Default to refuted=true if uncertain.\n\nStructured output only. Evidence MUST be specific."

// ─── Pipeline: search → dedup → fetch+extract (no barrier) — worker model ───
const searchResults = await pipeline(
  scope.angles,

  angle => agent(SEARCH_PROMPT(angle), {
    label: "search:" + angle.label, phase: "Search", schema: SEARCH_SCHEMA, model: WORKER_MODEL, agentType: WORKER_AGENT
  }).then(r => {
    if (!r) return null
    log(angle.label + ": " + r.results.length + " results")
    return { angle: angle.label, results: r.results }
  }),

  searchResult => {
    const sorted = [...searchResult.results].sort((a, b) => relRank[a.relevance] - relRank[b.relevance])
    const novel = sorted.filter(r => {
      const key = normURL(r.url)
      if (seen.has(key)) {
        dupes.push({ ...r, angle: searchResult.angle, dupOf: seen.get(key) })
        return false
      }
      if (fetchSlots <= 0 && relRank[r.relevance] >= 1) {
        budgetDropped.push({ ...r, angle: searchResult.angle })
        return false
      }
      seen.set(key, { angle: searchResult.angle, title: r.title })
      fetchSlots--
      return true
    })
    if (novel.length < searchResult.results.length) {
      log(searchResult.angle + ": " + novel.length + " novel (" + (searchResult.results.length - novel.length) + " filtered)")
    }
    return parallel(
      novel.map(source => () => {
        let host = "unknown"
        try { host = new URL(source.url).hostname.replace(/^www\./, "") } catch {}
        return agent(FETCH_PROMPT(source, searchResult.angle), {
          label: "fetch:" + host,
          phase: "Fetch",
          schema: EXTRACT_SCHEMA,
          model: WORKER_MODEL,
          agentType: WORKER_AGENT,
        }).then(ext => {
          if (!ext) return null
          return {
            url: source.url, title: source.title, angle: searchResult.angle,
            sourceQuality: ext.sourceQuality, publishDate: ext.publishDate,
            claims: ext.claims.map(c => ({ ...c, sourceUrl: source.url, sourceQuality: ext.sourceQuality })),
          }
        }).catch(e => {
          log("fetch failed: " + source.url + " — " + (e.message || e))
          return { url: source.url, title: source.title, angle: searchResult.angle, sourceQuality: "unreliable", claims: [] }
        })
      })
    )
  }
)

const allSources = searchResults.flat().filter(Boolean)
const allClaims = allSources.flatMap(s => s.claims)
const impRank = { central: 0, supporting: 1, tangential: 2 }
const qualRank = { primary: 0, secondary: 1, blog: 2, forum: 3, unreliable: 4 }

// Drop tangential claims entirely; rank the rest by importance then source quality.
const verifiable = allClaims.filter(c => c.importance !== "tangential")
const droppedTangential = allClaims.length - verifiable.length
const rankedClaims = [...verifiable]
  .sort((a, b) => (impRank[a.importance] - impRank[b.importance]) || (qualRank[a.sourceQuality] - qualRank[b.sourceQuality]))
  .slice(0, MAX_VERIFY_CLAIMS)

log("Fetched " + allSources.length + " sources → " + allClaims.length + " claims (" + droppedTangential + " tangential dropped) → verifying top " + rankedClaims.length)

if (rankedClaims.length === 0) {
  return {
    question: QUESTION,
    keyAssertions: KEY,
    summary: "No verifiable claims extracted. " + allSources.length + " sources fetched. " + dupes.length + " URL dupes, " + budgetDropped.length + " budget-dropped, " + droppedTangential + " tangential.",
    findings: [], refuted: [], sources: allSources.map(s => ({ url: s.url, quality: s.sourceQuality })),
    stats: { angles: scope.angles.length, sources: allSources.length, claims: 0, dupes: dupes.length },
  }
}

// ─── Verify: Haiku scan → conditional Sonnet escalation (2 diverse lenses) ───
phase("Verify")
const voteStr = c => c.votes.length ? (c.votes.length - c.refutedVotes) + "-" + c.refutedVotes : "abstain"

const verified = (await parallel(
  rankedClaims.map(claim => () => (async () => {
    // Stage 1 — Haiku scan (lens 1)
    const scan = await agent(SCAN_PROMPT(claim), {
      label: "scan:" + claim.claim.slice(0, 34),
      phase: "Verify",
      schema: SCAN_SCHEMA,
      model: SCAN_MODEL,
      agentType: WORKER_AGENT,
    })
    if (!scan) {
      return { ...claim, votes: [], refutedVotes: 0, escalated: false, survives: false, keyRelevant: false }
    }

    const weakSource = qualRank[claim.sourceQuality] >= 2 // blog/forum/unreliable
    const escalate =
      scan.refuted ||
      scan.confidence === "low" ||
      scan.keyRelevant ||
      (claim.importance === "central" && weakSource)

    if (!escalate) {
      log("scan ✓ \"" + claim.claim.slice(0, 44) + "…\" (" + scan.confidence + ", 1 vote)")
      return { ...claim, votes: [scan], refutedVotes: 0, escalated: false, survives: true, keyRelevant: scan.keyRelevant }
    }

    // Stage 2 — Sonnet escalation: lens 2 (contradiction) + lens 3 (quality/recency)
    const lenses = (await parallel([
      () => agent(LENS2_PROMPT(claim), { label: "lens2:" + claim.claim.slice(0, 28), phase: "Verify", schema: VERDICT_SCHEMA, model: WORKER_MODEL, agentType: WORKER_AGENT }),
      () => agent(LENS3_PROMPT(claim), { label: "lens3:" + claim.claim.slice(0, 28), phase: "Verify", schema: VERDICT_SCHEMA, model: WORKER_MODEL, agentType: WORKER_AGENT }),
    ])).filter(Boolean)

    const votes = [scan, ...lenses]
    const refutedVotes = votes.filter(v => v.refuted).length
    const survives = votes.length >= REFUTATIONS_REQUIRED && refutedVotes < REFUTATIONS_REQUIRED
    log("escalated " + votes.length + "-vote \"" + claim.claim.slice(0, 40) + "…\": " + (votes.length - refutedVotes) + "-" + refutedVotes + (survives ? " ✓" : " ✗") + (scan.keyRelevant ? " [key]" : ""))
    return { ...claim, votes, refutedVotes, escalated: true, survives, keyRelevant: scan.keyRelevant }
  })())
)).filter(Boolean)

const confirmed = verified.filter(c => c.survives)
const killed = verified.filter(c => !c.survives)
const escalatedCount = verified.filter(c => c.escalated).length
const verifyAgents = verified.length + 2 * escalatedCount // scans + 2 lenses per escalation
log("Verify done: " + verified.length + " claims (" + escalatedCount + " escalated, " + verifyAgents + " agents) → " + confirmed.length + " confirmed, " + killed.length + " killed")

if (confirmed.length === 0) {
  return {
    question: QUESTION,
    keyAssertions: KEY,
    summary: "All " + verified.length + " claims failed verification. Research inconclusive — sources may be low-quality or claims overstated.",
    findings: [],
    refuted: killed.map(c => ({ claim: c.claim, vote: voteStr(c), source: c.sourceUrl })),
    sources: allSources.map(s => ({ url: s.url, quality: s.sourceQuality, claimCount: s.claims.length })),
    stats: { angles: scope.angles.length, sources: allSources.length, claims: allClaims.length, verified: verified.length, escalated: escalatedCount, confirmed: 0, killed: killed.length, verifyAgents },
  }
}

// ─── Synthesize — session model (no `model` opt) ───
phase("Synthesize")
const confRank = { high: 0, medium: 1, low: 2 }
const block = confirmed.map((c, i) => {
  const best = c.votes.filter(v => !v.refuted).sort((a, b) => confRank[a.confidence] - confRank[b.confidence])[0] || c.votes[0] || { confidence: "low", evidence: "" }
  return "### [" + i + "] " + c.claim + (c.keyRelevant ? "  [KEY]" : "") + "\n" +
    "Vote: " + voteStr(c) + (c.escalated ? " (escalated)" : " (scan-pass)") + " · Source: " + c.sourceUrl + " (" + c.sourceQuality + ")\n" +
    "Quote: \"" + c.quote + "\"\nVerifier evidence (" + best.confidence + "): " + best.evidence + "\n"
}).join("\n")

const killedBlock = killed.length > 0
  ? "\n## Refuted claims (for transparency)\n" +
    killed.map(c => "- \"" + c.claim + "\" (" + c.sourceUrl + ", vote " + voteStr(c) + ")").join("\n")
  : ""

const report = await agent(
  "## Synthesis: research report\n\n" +
  "**Question:** " + QUESTION + "\n\n" +
  (KEY.length ? "**Key assertions to address:**\n" + KEY.map((k, i) => (i + 1) + ". " + k).join("\n") + "\n\n" : "") +
  confirmed.length + " claims passed verification. Merge semantic duplicates and synthesize.\n\n" +
  "## Confirmed claims\n" + block + "\n" + killedBlock + "\n\n" +
  "## Instructions\n" +
  "1. Identify claims that say the same thing — merge them, combine their sources.\n" +
  "2. Group related claims into coherent findings. Each finding should directly address the research question (prioritize the key assertions).\n" +
  "3. Assign confidence per finding: high (multiple primary sources, unanimous votes), medium (secondary sources or split votes), low (single source, scan-pass only, or blog-quality).\n" +
  "4. Write a 3-5 sentence executive summary answering the research question.\n" +
  "5. Note caveats: what's uncertain, what sources were weak, what time-sensitivity applies.\n" +
  "6. List 2-4 open questions that emerged but weren't answered.\n\nStructured output only.",
  { label: "synthesize", schema: REPORT_SCHEMA, agentType: WORKER_AGENT }
)

if (!report) {
  return {
    question: QUESTION,
    keyAssertions: KEY,
    summary: "Synthesis step was skipped or failed — returning " + confirmed.length + " verified claims unmerged.",
    findings: [],
    confirmed: confirmed.map(c => ({ claim: c.claim, source: c.sourceUrl, quote: c.quote, vote: voteStr(c) })),
    refuted: killed.map(c => ({ claim: c.claim, vote: voteStr(c), source: c.sourceUrl })),
    sources: allSources.map(s => ({ url: s.url, quality: s.sourceQuality, claimCount: s.claims.length })),
    stats: { angles: scope.angles.length, sources: allSources.length, claims: allClaims.length, verified: verified.length, escalated: escalatedCount, confirmed: confirmed.length, killed: killed.length, verifyAgents, afterSynthesis: 0 },
  }
}

// ─── Critique — completeness check vs key assertions (session model) ───
phase("Critique")
const critique = await agent(
  "## Completeness critic\n\n" +
  "**Question:** " + QUESTION + "\n\n" +
  "## Key assertions the report was meant to establish\n" + (KEY.length ? KEY.map((k, i) => (i + 1) + ". " + k).join("\n") : "(none specified)") + "\n\n" +
  "## Confirmed findings\n" + (report.findings.length ? report.findings.map(f => "- " + f.claim + " (" + f.confidence + ")").join("\n") : "(none)") + "\n\n" +
  "## Angles searched\n" + scope.angles.map(a => a.label).join(", ") + "\n\n" +
  "## Task\nAudit coverage — be specific and concrete:\n" +
  "1. unconfirmedKeyAssertions: list verbatim any key assertion NOT backed by a confirmed finding.\n" +
  "2. gaps: what angle, source type, time period, or sub-question went uncovered or under-sourced?\n" +
  "3. suggestedFollowups: 1-4 specific follow-up search queries that would close the biggest gaps.\n\nStructured output only.",
  { label: "critique", schema: CRITIC_SCHEMA, agentType: WORKER_AGENT }
)

return {
  question: QUESTION,
  keyAssertions: KEY,
  ...report,
  completeness: critique || { note: "critic returned no result" },
  refuted: killed.map(c => ({ claim: c.claim, vote: voteStr(c), source: c.sourceUrl })),
  sources: allSources.map(s => ({ url: s.url, quality: s.sourceQuality, angle: s.angle, claimCount: s.claims.length })),
  stats: {
    angles: scope.angles.length,
    keyAssertions: KEY.length,
    scanModel: SCAN_MODEL,
    workerModel: WORKER_MODEL,
    sourcesFetched: allSources.length,
    claimsExtracted: allClaims.length,
    tangentialDropped: droppedTangential,
    claimsVerified: verified.length,
    escalated: escalatedCount,
    confirmed: confirmed.length,
    killed: killed.length,
    afterSynthesis: report.findings.length,
    urlDupes: dupes.length,
    budgetDropped: budgetDropped.length,
    verifyAgents,
    agentCalls: 1 + scope.angles.length + allSources.length + verifyAgents + 1 + (critique ? 1 : 0),
  },
}

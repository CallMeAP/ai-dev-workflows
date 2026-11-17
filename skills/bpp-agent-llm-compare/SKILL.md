---
name: bpp-agent-llm-compare
description: Use when another LLM must be measured against Luna (the bpp-agent default Codex model) on the KI-Assistent — phrases like "compare llm", "qwen vs luna", "test another model against luna", "challenger model", "is Mixtral/Llama/Claude good enough for the agent", "tune the prompt for the local model", "/bpp-agent-llm-compare". Builds on bpp-agent-llm-selftest.
---

# bpp-agent-llm-compare

## Overview

Blind A/B of a **challenger** (Qwen, Mixtral, Llama, Claude, any OpenAI-compatible model) against **Luna** on the bpp-agent self-test
cases, then a tuning loop that only keeps a change when it wins on a **held-back** set the loop never saw. Output: a score report and,
if a change wins, a draft MR (label `bpp-agent`).

**REQUIRED SUB-SKILL:** bpp-agent-llm-selftest. Invoke it for the stack, the pre-flight, the env file, the case sets, `run-round.sh`,
`score.py` and its rules table. This skill adds only `scripts/` here: `detect.sh`, `challenger.sh`, `split.py`, `ab-run.sh`, `ab.py`,
and `compare.env.example`. Run them through their interpreter. Env: `SELFTEST_ENV` (main skill), `COMPARE_ENV` (copy of
`compare.env.example`), `JAR`, `COMPARE_RUN`.

## Rules (on top of the main skill's table)

| Rule | Enforced by |
|---|---|
| Install nothing and pull no model without the developer's answer. Detect, then ASK runtime + model. | you |
| `CHALLENGER_KIND=local` = a loopback endpoint; anything else is hosted. Hosted challengers see **synthetic data only**. The demo DB is a `pg_dump` copy of local `bpp`: hosted needs a DB the developer confirmed as synthetic (`SYNTHETIC_DATA_CONFIRMED=yes`). bpp-copy data only with local models. | `challenger.sh` refuses |
| Anthropic only through a **Console API key** of a workspace **with a spend limit**. Never a subscription OAuth token (`sk-ant-oat...`). | `challenger.sh` refuses the OAuth prefix; the spend limit is yours to check |
| Key in a mode-600 file, passed by variable name (`ApiKeyEnv`). Never printed, never in the env file, never committed. | `challenger.sh` |
| The tuning loop reads `tune/` only. Never open `heldback/`, its run dirs or their `blind/` files while proposing a change. | you (brief the tuning subagent with tune paths only) |
| Luna's path stays the default and unchanged: overlays never touch `Llm:Codex:*`, `Llm:SystemPrompt`, `Llm:DefaultProvider`. | `challenger.sh` refuses such overlay lines |
| `challenger.sh up/down` restarts the demo agent: a **global switch**, nothing else runs meanwhile; not while latency timers are pending. | `challenger.sh` refuses pending timers |

## Stop rules

- **Codex 95 % 5 h / 95 % week**: `ab-run.sh` exits 3 (main skill's quota guard). Luna, the judge (if Codex) and `--refresh` share one plan.
- **Hosted budget**: `ab-run.sh` exits 4 when `BUDGET_USD` is reached (agent_turn tokens x `PRICE_*`); the Console spend limit is the hard cap.
- **Iterations**: at most `MAX_ITER` (default 5) tuning iterations per run; also stop after 2 rejected candidates in a row.
- Exit 3/4: write the report with what ran, say which stop fired. Rerun the same command after a reset: finished cases are skipped.

## Run

### 1 Challenger setup (ask first)

```bash
C=~/.claude/skills/bpp-agent-llm-compare; S=~/.claude/skills/bpp-agent-llm-selftest
bash $C/scripts/detect.sh                    # runtimes, GPU, RAM, CPU, disk, local models, what answers on :8000/v1
```

Then ask the developer (AskUserQuestion; recommended option first), with the detect output in the question:

| Machine | Recommend |
|---|---|
| No GPU, <= 64 GB RAM | llama.cpp CPU, a 3-8B GGUF at Q8/Q4 (default `unsloth/Qwen3.5-4B-GGUF:Q8_0`, the existing `Llm:LlamaCpp` model). 30B+ is too slow to be useful. |
| NVIDIA GPU | llama.cpp with CUDA offload, or vLLM; model size by VRAM |
| Ollama already installed | Ollama (`/v1` endpoint) in the llamacpp slot |
| Hosted wanted | vendor + model + price; Anthropic: Console key + spend limit (see Rules); synthetic DB confirmed |

Start the runtime the developer chose. llama.cpp: e.g. `llama-server -hf <repo:quant> --jinja -c <ctx> -np 1 --port 8000` (check the
flags with `llama-server --help`; `--jinja` is required for tool calls per `ProvidersLlamaCppOptions`). Fill `compare.env` (`CHALLENGER_*`; `CHALLENGER_CONTEXT_TOKENS` = per-slot window, `-c` / `-np`).

How the challenger reaches the agent (`challenger.sh mode` prints it):

- **pref** (`CHALLENGER_PROVIDER=llamacpp`): llama.cpp, Ollama, vLLM, any key-less local server go into the `Llm:LlamaCpp` slot. Both
  arms stay up; `ab-run.sh` switches per case with `PUT /api/llm-provider-preference`, interleaved. The slot runs the llamacpp-only
  engine paths (no-think client, compact mail prompt, German retry): that is what a local model would run in production.
- **restart** (any other id, `Llm:OpenAiCompatible:<id>`): only `openai-codex` and `llamacpp` are selectable per GoUser, so
  `challenger.sh up` restarts the agent with only the challenger allowed and as default, `down` brings Luna back; one arm per block.
  Needs `$DEMO_HOME/start.sh` to read `Llm__DefaultProvider="${AGENT_DEFAULT_PROVIDER:-openai-codex}"` (it refuses otherwise).
- Anthropic: endpoint `https://api.anthropic.com/v1/` (OpenAI SDK compatibility layer, meant for testing and comparing models).
  There `temperature` < 1 is a 400 on Claude 4.7+ and `top_p` other than the default too, `strict` and `seed` are ignored, forced
  `tool_choice` is a 400 on Opus 5.5 / Sonnet 5.5: no sampling overlay for Claude. `CHALLENGER_CONTEXT_TOKENS` = the model's window.

```bash
bash $C/scripts/challenger.sh up             # restarts the demo agent; then re-run the main skill's pre-flight (catalog, SHA)
```

### 2 Split (70 % tune / 30 % held-back)

Cases: the main skill's `cases/*.json` (not `model-switch.json`) plus the repo fixtures you have seeds for (custscope, dashboard).
Before the split, a fresh subagent writes 1-2 **new** cases per suite into `$RUN_DIR/fresh.json` (ids `fr-<run>-...`, same schema,
checkable `expected`, German prompts on demo-copy customers). Brief it with the suite list and the schema only, never with existing
held-back cases.

```bash
python3 -I $C/scripts/split.py $RUN_DIR --seed "$SPLIT_SEED" --prev <last run's split.json> --fresh $RUN_DIR/fresh.json \
  $S/cases/{read,write,garbage,injection,mail-loop}.json <every earlier run's fresh.json>
```

Same seed + `--prev` keep every case in its set across runs (held-back never moves to tune). Fresh cases always go to held-back,
and earlier runs' fresh files (passed as case files) stay there, so the held-back set grows run by run.
`split.json` stays in the run dir.

### 3 Baseline A/B (both sets, both arms)

```bash
export COMPARE_RUN=$(basename $RUN_DIR)-i0
bash $C/scripts/ab-run.sh $RUN_DIR/tune     $RUN_DIR/i0-tune     luna challenger   # pref mode; restart mode: one arm per call
bash $C/scripts/ab-run.sh $RUN_DIR/heldback $RUN_DIR/i0-heldback luna challenger
```

Restart mode: `challenger.sh up` -> `ab-run.sh <set> <out> challenger`; `challenger.sh down` -> `ab-run.sh <set> <out> luna`.

### 4 Blind judge

```bash
python3 -I $C/scripts/ab.py blind $RUN_DIR/i0-tune --seed $COMPARE_RUN     # same for i0-heldback
```

One fresh subagent per suite gets `blind/<suite>.jsonl` only (never `key.json`, the arm dirs or this skill's text about the models).
Per case: `X` / `Y` = `PASS` / `FAIL` against the rubric (null when that slot is null = hard-failed), `better` = `X` / `Y` / `tie`, one-line
reason; it returns `[{id, X, Y, better, reason}]` and you write `blind/<suite>.verdicts.json`. Then `ab.py score <out>`.

**Self-preference:** a judge prefers its own family. Claude subagent judge + Claude challenger, or a Codex/GPT judge + Luna, is biased.
Use a judge of a third family where possible; otherwise judge with both families and report where they disagree. Export
`JUDGE_FAMILY` (e.g. `claude`) for the report.

### 5 Tuning loop (tune set only)

Per iteration `i` (1..`MAX_ITER`):

1. A tuning subagent reads `i<prev>-tune` results only (score.json, the answers, `summary.json`) and proposes **one** change:
   - **overlay** (default, challenger only): prompt additions, sampling, tool-description overrides for the challenger's provider.
     As env lines in an overlay file where config already has the key (`Llm__LlamaCpp__WorkThinking`, `__EvalThinking`,
     `__EvalTemperature`, `Llm__OpenAiCompatible__<id>__MaxToolsPerRequest`). A per-provider prompt/tool-description overlay does
     not exist on origin/development (checked 2026-11-17: no overlay type in `BPP.Agent.NET.Providers`; `Llm:SystemPrompt` is shared).
     Re-check with `git grep -n -i overlay origin/development -- '*.cs'`. If still missing, the first candidate is a bpp-agent branch
     that adds e.g. `Llm:ProviderOverlays:<provider>` (`SystemPromptAddition`, sampling, `ToolDescriptions`), applied only when the
     session's provider matches, with a unit test that the Codex request is byte-identical without an overlay. Build it into the demo
     agent worktree (main skill, "Switching the agent to another build"); `*.Tests` projects only.
   - **shared** (prompt or tool text both arms use): allowed only with the Luna check in step 3.
2. `export COMPARE_RUN=$(basename $RUN_DIR)-i$i` (new mail subjects per iteration), `challenger.sh up <overlay.env>`,
   `ab-run.sh $RUN_DIR/tune $RUN_DIR/i$i-tune challenger`, blind + judge + score. No tune gain: reject, next.
3. Tune gain: `ab-run.sh $RUN_DIR/heldback $RUN_DIR/i$i-heldback challenger` (shared change: `luna challenger`), blind + judge + score, then
   `python3 -I $C/scripts/ab.py gate <last accepted heldback dir> $RUN_DIR/i$i-heldback [--shared]`.
   ACCEPT = challenger held-back final passes rise, no new HARD-FAIL, no wrong-arm turn, and with `--shared` no Luna case lost.
4. Only the gate decides. A tune-only gain is never accepted; tell the tuning subagent "rejected on held-back", nothing more.

### 6 Report and MR

```bash
python3 -I $C/scripts/ab.py report $RUN_DIR i0-tune=$RUN_DIR/i0-tune i0-heldback=$RUN_DIR/i0-heldback i1-tune=... i1-heldback=...
bash $C/scripts/challenger.sh down
```

`REPORT.md` shows per label and arm hard passes, HARD-FAILs, final passes, pairwise wins, wrong-arm turns, and the tune vs held-back
gap per iteration (gap > 15 pts = overfitting). Add the model, runtime, machine, Codex % start/end (`codex-usage.sh`), spend, stop
reason, the judge family and the rejected candidates in one line each.

At least one accepted change: commit the overlay (config + code) on a branch off bpp-agent `development` (merge, never rebase/amend/force;
`git commit -- <paths>`), push, and open a **draft** MR with label `bpp-agent`, the report in the description (the push of a new
branch can auto-open an MR to development: make that one the draft instead of opening a second). No accepted change: report only, no MR.
Never merge.

## Common mistakes

- Reading held-back answers "just to understand a failure": the held-back score is then worthless for this run. Start a new run with fresh cases.
- Changing `SPLIT_SEED` or omitting `--prev`: held-back cases move into tune.
- Same `SELFTEST_RUN_ID` for both arms: their synthetic mails share a thread. `ab-run.sh` sets `<COMPARE_RUN>-<arm>`; keep `COMPARE_RUN` unique per iteration.
- A provider that is not selectable (`openai-compatible` id) run in pref mode: sessions silently start on Luna. `ab.py score` lists those as wrong-arm.
- `CHALLENGER_CONTEXT_TOKENS` left at 32768 for a hosted model: the agent budgets every request as if the window were 32k (D-101).
- Judging with the arm names in the brief, or with timing/token data: slow local answers give the arm away.

# bpp-agent-llm-compare

Blind A/B of a challenger LLM (Qwen, Mixtral, Llama, Claude, any OpenAI-compatible model) against Luna on the bpp-agent self-test
cases, with a 70/30 tune/held-back split and a tuning loop whose changes are accepted on held-back gains only. Builds on
`bpp-agent-llm-selftest` (stack, pre-flight, cases, `run-round.sh`, `score.py`); this skill adds no copy of those scripts.

## Placeholders

- No machine path of the developer is hard-coded: scripts use `$HOME`, `SELFTEST_SKILL` (default
  `~/.claude/skills/bpp-agent-llm-selftest`) and the two env files.
- No user name, e-mail address or secret is in the skill. API keys live in a mode-600 file named by `CHALLENGER_KEY_FILE`.

## Prerequisites

- `bpp-agent-llm-selftest` installed and its demo stack running (see its README), `selftest.env` filled, Codex linked.
- A challenger: a local runtime (llama.cpp `llama-server --jinja`, Ollama, vLLM) the developer chose after `detect.sh`, or a hosted
  vendor key (Anthropic: Console API key of a workspace with a spend limit; hosted only on a DB confirmed as synthetic).
- Hosted or keyed challengers (restart mode): `$DEMO_HOME/start.sh` must read
  `Llm__DefaultProvider="${AGENT_DEFAULT_PROVIDER:-openai-codex}"` on the agent line.
- Tools: as for the main skill (bash, curl, jq, psql, python3, node), plus `awk`, `systemctl --user`.

## Layout

- `SKILL.md`: the procedure. `compare.env.example`: env template (challenger, prices, budget, iterations, split seed).
- `scripts/detect.sh`: machine and runtime detection, read-only.
- `scripts/challenger.sh`: `up [overlay.env]` / `down` / `mode`; restarts the demo agent with the challenger (pref or restart mode), refuses unsafe setups.
- `scripts/split.py`: deterministic stratified 70/30 split, stable across runs with `--prev`, fresh cases into held-back.
- `scripts/ab-run.sh`: runs a set on both arms (interleaved per case in pref mode) via the main skill's `run-round.sh` + `score.py`;
  Codex 95/95 stop (exit 3), hosted budget stop (exit 4).
- `scripts/ab.py`: `blind` (judge input without arm names), `score` (unblind, wrong-arm check), `gate` (held-back acceptance,
  Luna no-regression with `--shared`), `report` (REPORT.md with the tune vs held-back gap).

## Install by hand

Copy the folder to `~/.claude/skills/bpp-agent-llm-compare/`, then `cp compare.env.example $DEMO_HOME/compare.env` and fill it.

## Verify

```bash
bash ~/.claude/skills/bpp-agent-llm-compare/scripts/detect.sh
SELFTEST_ENV=$DEMO_HOME/selftest.env COMPARE_ENV=$DEMO_HOME/compare.env JAR=<jar> bash ~/.claude/skills/bpp-agent-llm-compare/scripts/challenger.sh mode
python3 -I ~/.claude/skills/bpp-agent-llm-compare/scripts/split.py /tmp/split-check --seed bpp-agent-llm-compare-v1 \
  ~/.claude/skills/bpp-agent-llm-selftest/cases/{read,write,garbage,injection,mail-loop}.json
```

Expected: detect prints runtimes/GPU/RAM without changing anything; `mode` prints `pref` or `restart`; the split prints about 30 %
held-back per suite. None of these makes an LLM call or restarts anything.

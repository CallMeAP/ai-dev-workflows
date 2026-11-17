#!/usr/bin/env bash
# Prints what this machine can run a local challenger on: runtimes (llama.cpp, Ollama, vLLM), GPU, RAM, CPU, free disk, local GGUF
# files and Ollama models, and whether something already answers on the agent's Llm:LlamaCpp endpoint. Read-only: installs,
# downloads and starts nothing. The developer picks the runtime and model from this output (SKILL.md step 1).
# Usage: bash detect.sh [llamacpp-endpoint, default http://127.0.0.1:8000/v1]
EP=${1:-http://127.0.0.1:8000/v1}
have() { command -v "$1" >/dev/null 2>&1; }
echo "== runtimes"
for b in llama-server llama-cli ollama vllm; do printf '%-13s %s\n' "$b" "$(command -v "$b" || echo none)"; done
have python3 && python3 -I -c 'import vllm' 2>/dev/null && echo "vllm python module: yes"
echo "== gpu"
if have nvidia-smi; then nvidia-smi --query-gpu=name,memory.total,memory.used --format=csv,noheader
else echo "nvidia-smi: none"; fi
have rocm-smi && rocm-smi --showproductname 2>/dev/null | head -5
echo "== cpu / ram / disk"
echo "cores $(nproc), $(grep -m1 'model name' /proc/cpuinfo | cut -d: -f2- | sed 's/^ //')"
grep -q -w avx2 /proc/cpuinfo && echo "avx2: yes" || echo "avx2: no"
free -g | awk '/^Mem:/ {print "ram total " $2 " GB, available " $7 " GB"}'
df -h "$HOME" | awk 'NR==2 {print "disk free in $HOME " $4}'
echo "== local models"
find "$HOME/.cache/llama.cpp" "$HOME/.cache/huggingface" "$HOME/models" -name '*.gguf' -size +100M 2>/dev/null | head -20
have ollama && ollama list 2>/dev/null | head -20
echo "== endpoint $EP"
if curl -fsS --max-time 5 "$EP/models" -o /tmp/.llm-compare-models.$$ 2>/dev/null; then
  jq -r '.data[]?.id' /tmp/.llm-compare-models.$$ 2>/dev/null | sed 's/^/serving: /'; rm -f /tmp/.llm-compare-models.$$
else echo "nothing answers on $EP"; fi

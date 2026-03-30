# nemoclaw-agent-config

Boilerplate repository for managing NemoClaw AI agent configuration, policies, and analysis.

## Directory Structure

```
nemoclaw-agent-config/
  policies/
    openclaw-sandbox.yaml   # Base policy (network/FS/process)
    presets/                 # Policy presets
      discord.yaml
      docker.yaml
      huggingface.yaml
      jira.yaml
      npm.yaml
      outlook.yaml
      pypi.yaml
      slack.yaml
      telegram.yaml
  blueprint.yaml            # Inference profile / sandbox settings
  sandboxes.json            # Sandbox registration state snapshot
  scripts/
    apply.sh                # Policy apply helper
```

## Makefile

NemoClaw lifecycle management is centralized via `make` commands.

| Command | Description |
|---|---|
| `make install` | Install NemoClaw (`nemoclaw-install-safe.sh`) |
| `make start` | Sync config, then apply policy + start service if sandbox exists, otherwise run full onboarding |
| `make stop` | Stop service (sandbox is preserved) |
| `make destroy` | Stop service + destroy sandbox |
| `make status` | Show sandbox and service status |
| `make logs` | Tail gateway + sandbox logs |
| `make sync` | Copy config to NemoClaw source tree (no restart) |
| `make apply` | Dynamically apply policy to running sandbox (no restart) |
| `make connect` | Open a shell into the sandbox |

### Configuration Variables

| Variable | Default | Description |
|---|---|---|
| `SANDBOX` | `my-agent` | Target sandbox name |
| `NEMOCLAW_HOME` | `$HOME/.nemoclaw` | NemoClaw home directory |

Variables can be overridden via environment variables or command-line arguments.

```bash
# Example: start with a different sandbox name
make start SANDBOX=my-sandbox
```

## Installer (`nemoclaw-install-safe.sh`)

A safe installer for NemoClaw that confines all artifacts under `~/.nemoclaw`, minimizing impact on the host system.

### Changes from Upstream

| Feature | Upstream | Safe variant |
|---------|----------|--------------|
| nvm auto-install | Yes | Removed -- Node.js must already be on PATH |
| Ollama auto-install | Yes | Removed |
| `npm link` (global) | Yes | Removed -- replaced with local `--prefix` install |
| `--uninstall` | No | Added |
| `--dry-run` | No | Added |
| `--upgrade` / `--rollback` / `--prune` | No | Added |
| Trap-based cleanup on error | No | Added |
| Git clone commit hash recording | No | Added |
| Versioned directory layout with symlinks | No | Added |

### Prerequisites

- Node.js >= 20 (recommended: 22)
- npm >= 10
- git
- bash (with `set -Eeuo pipefail` support)

### Directory Layout

```
~/.nemoclaw/
  source            -> source-v0.2.0  (symlink)
  prefix            -> prefix-v0.2.0  (symlink)
  source-v0.1.0/                      (previous version source)
  prefix-v0.1.0/                      (previous version prefix)
  source-v0.2.0/                      (current version source)
  prefix-v0.2.0/                      (current version prefix)
    bin/
      nemoclaw                        (CLI entry point)
  sandboxes.json                      (sandbox registry)
  .active-version                     (current active version tag)
  .version-history                    (rollback history stack, max 3 entries)
  .install.lock                       (concurrent execution lock)
```

The base directory can be changed via the `NEMOCLAW_HOME` environment variable (default: `~/.nemoclaw`).

### Usage

#### Fresh Install

```bash
bash nemoclaw-install-safe.sh
```

Steps performed:

1. Verify Node.js / npm versions
2. Clone source from GitHub into a versioned directory
3. Install dependencies (`npm install --ignore-scripts`)
4. Build the NemoClaw plugin
5. Install the CLI to a versioned local prefix (`npm install --global --prefix`)
6. Activate the version via symlinks
7. Run `nemoclaw onboard`

If a NemoClaw `package.json` exists in the same directory as the installer, it installs from local source instead of cloning from GitHub.

#### Upgrade

```bash
bash nemoclaw-install-safe.sh --upgrade
```

Fetches the latest release tag from the GitHub Releases API, installs the new version, and switches the active symlinks. The previous version is preserved in the history stack.

#### Rollback

```bash
bash nemoclaw-install-safe.sh --rollback
```

Reverts to the previous version using the history stack (`.version-history`).

#### Prune

```bash
bash nemoclaw-install-safe.sh --prune
```

Removes all installed versions older than the currently active one (semver comparison only).

#### Uninstall

```bash
bash nemoclaw-install-safe.sh --uninstall
```

Removes the entire `~/.nemoclaw` directory. Any PATH entries added to shell profiles must be removed manually.

#### Dry Run

```bash
bash nemoclaw-install-safe.sh --dry-run
```

Previews what actions would be taken without making any changes. Can be combined with other flags.

### Options

| Option | Description |
|--------|-------------|
| `--non-interactive` | Skip prompts (use env vars / defaults) |
| `--dry-run` | Preview actions without making changes |
| `--upgrade` | Upgrade to the latest stable release |
| `--rollback` | Roll back to the previous version |
| `--prune` | Remove versions older than the active one |
| `--uninstall` | Remove NemoClaw and all its artifacts |
| `--version`, `-v` | Print installer version and exit |
| `--help`, `-h` | Show help message and exit |

### Environment Variables

| Variable | Description |
|----------|-------------|
| `NVIDIA_API_KEY` | API key (skips credential prompt) |
| `NEMOCLAW_HOME` | Base directory (default: `~/.nemoclaw`) |
| `NEMOCLAW_GIT_REF` | Git tag/branch to clone (default: HEAD) |
| `NEMOCLAW_NON_INTERACTIVE=1` | Same as `--non-interactive` |
| `NEMOCLAW_SANDBOX_NAME` | Sandbox name to create/use |
| `NEMOCLAW_RECREATE_SANDBOX=1` | Recreate an existing sandbox |
| `NEMOCLAW_PROVIDER` | `cloud` / `ollama` / `nim` / `vllm` |
| `NEMOCLAW_MODEL` | Inference model to configure |
| `NEMOCLAW_POLICY_MODE` | `suggested` / `custom` / `skip` |
| `NEMOCLAW_POLICY_PRESETS` | Comma-separated policy presets |
| `NEMOCLAW_EXPERIMENTAL=1` | Show experimental/local options |
| `CHAT_UI_URL` | Chat UI URL to open after setup |
| `DISCORD_BOT_TOKEN` | Auto-enable Discord policy support |
| `SLACK_BOT_TOKEN` | Auto-enable Slack policy support |
| `TELEGRAM_BOT_TOKEN` | Auto-enable Telegram policy support |

### Safety Design

- Lockfile: `.install.lock` prevents concurrent installs. Stale locks from dead processes are automatically removed.
- Trap cleanup: On install failure, partial directories are automatically removed and backups are restored.
- Backup/restore: Existing version directories are backed up before overwriting.
- Atomic symlinks: Version switching uses `mv -T` (atomic `rename(2)` on Linux) with `ln -sfn` fallback.
- Tarball validation: Pre-extraction of the openclaw package checks SHA-256 checksums, path traversal entries, symbolic links, and executable files.
- Version string validation: Only `[a-zA-Z0-9._+-]` is allowed. `..` and slashes are rejected.
- NEMOCLAW_HOME validation: System directories (`/`, `/usr`, `/etc`, etc.) are rejected.
- Source hijack prevention: A `package.json` in CWD is only used if CWD matches the installer directory.

## Config Files and How to Apply Changes

Each config file has a distinct role, and the method for applying changes differs.

| File | Role | Hot Reload | How to Apply |
|---|---|---|---|
| `policies/openclaw-sandbox.yaml` | Network allowlist, FS permissions, process constraints | Yes | `make apply` |
| `blueprint.yaml` | Sandbox image, inference profile, port settings | No | `make destroy` → `make install` |
| `sandboxes.json` | Sandbox registration state snapshot | N/A | Do not edit manually (read-only reference) |

### openclaw-sandbox.yaml (Policy)

Can be applied dynamically at runtime. No restart of OpenClaw or the sandbox is required.

```bash
# Recommended: via Makefile
make apply

# Manual
openshell policy set --policy policies/openclaw-sandbox.yaml --wait my-agent

# Via script
./scripts/apply.sh my-agent
```

Key sections of the policy:

- `filesystem_policy` — read_only / read_write path controls
- `network_policies` — per-host access permissions; `binaries` can restrict by process
- `process` — execution user/group

To add a new host to the network policy, append it under the `network_policies:` section and run `make apply` for immediate effect.

Note on the `binaries` field: if you do not specify the permitted binary path, access from the agent (openclaw) will be blocked. To allow the agent to access a host, add `{ path: /usr/local/bin/openclaw }`.

### blueprint.yaml (Blueprint)

Static configuration baked in at sandbox creation time. Changes require recreating the sandbox.

```bash
make destroy
make install
```

However, inference settings (model changes) can be changed dynamically:

```bash
openshell inference update --model nvidia/nemotron-3-nano-30b-a3b
```

### sandboxes.json

This is not a config file read by NemoClaw — it is a state record on the repository side. No manual editing required.

## Architecture

### Inference Request Flow

```
Agent (inside sandbox) → OpenShell Gateway (proxy) → NVIDIA API (integrate.api.nvidia.com)
```

The agent cannot communicate directly with the outside. All network requests pass through the OpenShell gateway, and only endpoints permitted by policy are reachable.

### OpenClaw Workspace Files

Located at `/sandbox/.openclaw/workspace/` inside the sandbox and injected into the system prompt at session startup.

| File | Role | Updated By |
|---|---|---|
| `SOUL.md` | Agent personality, behavioral rules, and constraints | Human (manual edits) |
| `USER.md` | User information (preferences, how to address them, context) | Human (manual edits) |
| `MEMORY.md` | Long-term memory (accumulated learnings and decisions) | Agent (auto-appended) |

Writing to MEMORY.md requires `/sandbox/.openclaw/workspace` to be included in `filesystem_policy.read_write`.

### TUI vs Dashboard

OpenClaw v2026.3.x TUI has a streaming rendering regression ([#33768](https://github.com/openclaw/openclaw/issues/33768)). If responses are not displayed in real time and appear in bulk upon reconnection, use the Dashboard instead (`openclaw dashboard --no-open`).

---

## NemoClaw Cloud Models Analysis (2026-03-24)

Comparative analysis of 6 models available via NVIDIA API Key (`nvidia/nemotron-3-super-120b-a12b` is the default recommendation) with NemoClaw.

### Architecture Overview

| Model | Total Params | Active | Architecture | Context | Multimodal | License |
|---|---|---|---|---|---|---|
| Nemotron 3 Super 120B | 120B | 12B | Mamba2-Transformer Hybrid MoE + MTP | 1M | No | NVIDIA Open |
| Kimi K2.5 | 1T | 32B | Transformer MoE + MLA | 256K | Yes (image/video) | Modified MIT |
| GLM-5 | 744B | 40B | MoE (256 experts, top-8) | 200K | No | MIT |
| MiniMax M2.5 | 230B | 10B | MoE + Lightning Attention | 200K | No | Modified MIT |
| Qwen3.5 397B | 397B | 17B | Hybrid MoE + Gated DeltaNet | 262K (1M extendable) | Yes (image/video) | Apache 2.0 |
| GPT-OSS 120B | 117B | 5.1B | Transformer MoE (128 experts, top-4) | 128K | No | Apache 2.0 |

All models use MoE architecture. GPT-OSS 120B has the smallest active parameters (5.1B); Kimi K2.5 has the largest total parameters (1T).

### Cross-Benchmark Comparison

| Benchmark | Nemotron 3 Super | Kimi K2.5 | GLM-5 | MiniMax M2.5 | Qwen3.5 397B | GPT-OSS 120B |
|---|---|---|---|---|---|---|
| SWE-bench Verified | 60.5% | 76.8% | 77.8% | **80.2%** | 76.4% | 62.4% |
| AIME 2025 | 90.2% | 96.1% | 93.3% | 78-86% | 91.3% | **97.9%** |
| GPQA Diamond | 82.7% | 87.6% | 86.0% | 85.2% | **88.4%** | 80.9% |
| MMLU-Pro | 83.7% | -- | -- | 74% | 87.8% | **90.0%** |
| HLE (with tools) | 18.3% | **50.2%** | 50.4% | 32% | 28.7% | 19.0% |
| LiveCodeBench | 81.2% | 83-85% | 52.0% | -- | 83.6% | **88.0%** |
| IFEval (instruction following) | -- | -- | 88.0% | 88% | **92.6%** | -- |
| AA Intelligence Index | 36 | 47 | **50** | 42 | 45 | 33 |

### Inference Speed and Cost

| Model | Throughput | Input $/1M tok | Output $/1M tok | Verbosity |
|---|---|---|---|---|
| Nemotron 3 Super | **415 t/s** | $0.10-0.30 | $0.50-0.75 | Extremely high (110M tok) |
| Kimi K2.5 | 40 t/s | $0.60 | $2.50 | High (89M tok) |
| GLM-5 | Medium | $0.72-1.00 | $2.30-3.20 | Medium |
| MiniMax M2.5 | 50-100 t/s | **$0.15-0.30** | **$1.20-2.40** | High (56M tok) |
| Qwen3.5 397B | 84 t/s | $0.39-0.60 | $2.34-3.60 | Medium (86M tok) |
| GPT-OSS 120B | 190 t/s | $0.04-0.15 | $0.19-0.60 | High |

Verbosity refers to total output tokens generated during benchmark evaluation. This significantly affects effective cost.

### Model Details

#### 1. Nemotron 3 Super 120B (nvidia/nemotron-3-super-120b-a12b) — Default Recommendation

- Released: 2026-03-11
- Mamba2-Transformer hybrid + LatentMoE + Multi-Token Prediction
- 120B total / 12B active, native 1M context
- NVFP4 native training. Runs on a single B200 GPU or DGX Spark

Strengths:
- Overwhelming throughput (415 t/s, 5x the class median)
- Minimal accuracy degradation at 1M context (RULER@1M: 91.75%)
- Strong agent benchmarks (PinchBench 85.6%, DeepResearch Bench #1)
- TTFT 0.70s (half the median of 1.43s)
- Math HMMT Feb25: 94.73% (with tool use)

Weaknesses:
- Extreme verbosity (110M tokens generated during evaluation, median 7.3M)
- SWE-bench Verified 60.5% significantly trails coding-specialized models
- Lags behind Qwen3.5 on knowledge-density benchmarks (GPQA, MMLU-Pro, HLE)
- Some conversation quality issues on Arena-Hard-V2 (73.88 vs GPT-OSS 90.26)
- Supports only 7 languages

Sources:
- [NVIDIA Tech Blog](https://developer.nvidia.com/blog/introducing-nemotron-3-super-an-open-hybrid-mamba-transformer-moe-for-agentic-reasoning/)
- [Hugging Face](https://huggingface.co/nvidia/NVIDIA-Nemotron-3-Super-120B-A12B-BF16)
- [Artificial Analysis](https://artificialanalysis.ai/models/nvidia-nemotron-3-super-120b-a12b)

#### 2. Kimi K2.5 (moonshotai/kimi-k2.5)

- Released: 2026-01-27 (Moonshot AI)
- 1T parameters (32B active), 384 experts top-8, MLA
- Native multimodal (MoonViT-3D), 256K context

Strengths:
- HLE (with tools) 50.2% — top among all models
- Agent Swarm (up to 100 parallel sub-agents, 4.5x reduction in execution time)
- BrowseComp 74.9% (far exceeds GPT-5.2's 59.2%)
- AIME 2025: 96.1%
- OCRBench 92.3%, strong multimodal vision overall

Weaknesses:
- Slow inference speed (40 t/s, median 58.5 t/s)
- High hallucination rate (AA-Omniscience: -11)
- Extreme verbosity (89M tokens)
- Agent Swarm is in beta (reports of duplicate output and coordination failures)
- Weak at English creative writing
- Data privacy / Chinese regulatory concerns

Sources:
- [Hugging Face](https://huggingface.co/moonshotai/Kimi-K2.5)
- [Artificial Analysis](https://artificialanalysis.ai/models/kimi-k2-5)
- [Kimi K2.5 Tech Blog](https://www.kimi.com/blog/kimi-k2-5)

#### 3. GLM-5 (z-ai/glm5)

- Released: 2026-02-11 (Zhipu AI)
- 744B total / 40B active, 256 experts top-8
- Trained on ~100,000 Huawei Ascend chips (NVIDIA-independent)
- 200K context

Strengths:
- AA Intelligence Index 50 — first open-weight model to exceed 50
- MATH-500: 97.4% (surpasses Claude Opus 4.6's 96.4%)
- SWE-bench Verified 77.8%, Multilingual 73.3%
- Chatbot Arena Elo 1451 (highest among open-weight models)
- MIT license, API pricing 1/5–1/8 of Claude Opus

Weaknesses:
- Text only (no multimodal support)
- Self-hosting requires ~1,490 GB (BF16) — minimum 8x B200 needed
- LiveCodeBench 52.0 (significant drop from GLM-4.7's 84.9)
- Tendency to "overthink" even on simple tasks
- HLE score instability in independent evaluation (22.4% → regressed to 10.4%)
- 200K context is shorter than competitors

Sources:
- [GLM-5 Official](https://glm5.net/)
- [Hugging Face](https://huggingface.co/zai-org/GLM-5)
- [Artificial Analysis](https://artificialanalysis.ai/models/glm-5)
- [arXiv: 2602.15763](https://arxiv.org/abs/2602.15763)

#### 4. MiniMax M2.5 (minimaxai/minimax-m2.5)

- Released: 2026-02-12 (MiniMax)
- 230B total / 10B active, 256 experts top-8 + Lightning Attention
- 200K context, CISPO algorithm + large-scale RL

Strengths:
- SWE-bench Verified **80.2%** — frontier-class (nearly on par with Opus 4.6: 80.8%)
- BFCL multi-turn tool call 76.8 (far exceeds Claude 4.5: 68.0)
- Outstanding cost efficiency (1/10–1/20 of Opus 4.6)
- Modified MIT license, open-weight

Weaknesses:
- Infinite loop bugs reported frequently
- Reward hacking (tendency to skip tests rather than pass them)
- Weak general reasoning (AIME 78-86%, Intelligence Index 42)
- Gap between official benchmarks and independent evaluations (GPQA: 85.2% vs 47%)
- Text only (no multimodal support)
- Context rot (quality degrades on long inputs)

Sources:
- [MiniMax Official](https://www.minimax.io/news/minimax-m25)
- [Hugging Face](https://huggingface.co/MiniMaxAI/MiniMax-M2.5)
- [Artificial Analysis](https://artificialanalysis.ai/models/minimax-m2-5)

#### 5. Qwen3.5 397B (qwen/qwen3.5-397b-a17b)

- Released: 2026-02-16 (Alibaba / Qwen)
- 397B total / 17B active, Hybrid MoE + Gated DeltaNet
- Native multimodal (image/video), 262K (1M with YaRN extension), 201 languages

Strengths:
- Extremely high parameter efficiency (17B active, competitive with rivals)
- GPQA Diamond 88.4%, MMLU-Pro 87.8%
- Native multimodal (surpasses GPT-5.2 on math vision tasks)
- IFEval 92.6% (top-class instruction following)
- 201 languages, Apache 2.0 license
- 8.6x–19x faster decoding than Qwen3-Max

Weaknesses:
- Hallucination rate 88% (AA-Omniscience: -32, worst among all models)
- HLE 28.7% (significantly trails Gemini 3 Pro's 44.4% on hardest tasks)
- Self-hosting requires ~807 GB (full precision)
- Large reasoning token overhead

Sources:
- [Hugging Face](https://huggingface.co/Qwen/Qwen3.5-397B-A17B)
- [Qwen Blog](https://qwen.ai/blog?id=qwen3.5)
- [Artificial Analysis](https://artificialanalysis.ai/models/qwen3-5-397b-a17b)

#### 6. GPT-OSS 120B (openai/gpt-oss-120b)

- Released: 2025-08-05 (OpenAI)
- 117B total / 5.1B active, 128 experts top-4
- OpenAI's first open-weight model since GPT-2, Apache 2.0
- 128K context, text only

Strengths:
- AIME 2025: 97.9%, MMLU-Pro 90.0% — top-class in math and knowledge
- Codeforces Elo 2,622 (best in competitive programming)
- Remarkable efficiency with the smallest active parameters (5.1B)
- Can run on a single H100 (checkpoint 60.8 GiB)
- Among the cheapest ($0.04-0.15 / $0.19-0.60)

Weaknesses:
- Text only, no multimodal support
- Knowledge cutoff May 2024 (oldest among models)
- English-centric, weaker performance in non-English languages
- Loop issue (thinking can loop without producing a response)
- SWE-bench Verified 62.4% trails agent-focused models
- 128K context is the shortest among all models

Sources:
- [OpenAI Official](https://openai.com/index/introducing-gpt-oss/)
- [arXiv Model Card](https://arxiv.org/html/2508.10925v1)
- [Hugging Face](https://huggingface.co/openai/gpt-oss-120b)
- [Artificial Analysis](https://artificialanalysis.ai/models/gpt-oss-120b)

### Use Case Recommendations

| Use Case | Recommended Model | Reason |
|---|---|---|
| NemoClaw agent general use | Nemotron 3 Super 120B | NVIDIA-native integration, 1M context, #1 on agent benchmarks, fastest |
| Coding-focused | MiniMax M2.5 | SWE-bench 80.2% frontier-class, strongest tool calls, cheapest |
| General intelligence (best open) | GLM-5 | AA Intelligence Index 50, highest-ranked open-weight on Chatbot Arena |
| Math / competitive programming | GPT-OSS 120B | AIME 97.9%, Codeforces 2622, smallest active parameters |
| Multimodal + agent | Kimi K2.5 | HLE 50.2% #1 overall, Agent Swarm, vision integration |
| Multilingual / balanced | Qwen3.5 397B | 201 languages, multimodal, instruction following 92.6% |

### Common Caveats

- Verbosity: All models tend to generate large numbers of tokens. Nemotron, Kimi, and MiniMax are especially notable.
- Hallucination: GLM-5 is the lowest; Qwen3.5 is the highest.
- Benchmarks vs. real-world: Official scores and independent evaluations can diverge (especially MiniMax M2.5).
- Self-hosting: All models require large-scale GPUs. Use via NVIDIA API is assumed.

## License

Apache License 2.0

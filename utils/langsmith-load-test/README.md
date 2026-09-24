# LangSmith trace ingestion load test

Run a local agent that replies with dummy data and sends its traces to your LangSmith instance. It makes no calls to model providers and incurs no model charges. Your usual infrastructure costs still apply.

## Set up

You need Python 3.11+, [uv](https://docs.astral.sh/uv/getting-started/installation/), and access to your instance. From this folder, create `.env`:

```bash
cp .env.example .env
```

Edit `.env`:

| Setting | What to enter |
| --- | --- |
| `LANGSMITH_TRACING` | Set to `true` to upload traces. Set to `false` to run locally without uploads or feedback. |
| `LANGSMITH_ENDPOINT` | Your self-hosted API URL, such as `https://langsmith.example.com/api/v1`. |
| `LANGSMITH_API_KEY` | An API key created in the target LangSmith instance that can create projects, traces, and feedback. |
| `LANGSMITH_PROJECT` | The project to create or reuse, such as `load-test`. |
| `LANGSMITH_WORKSPACE_ID` | The target workspace ID from **Settings > General**. Set it only when the API key can access multiple workspaces. |

Leave the workspace ID empty when the API key is restricted to one workspace.

The API key identifies the organization; the workspace ID selects the workspace within it. No separate organization ID is needed. Traces, project creation, and feedback use the same credentials and workspace. When tracing is enabled, the script prints the resolved project and workspace before starting.

Keep `.env` private. The script loads it from this folder when it starts; its values take precedence over matching settings exported in your shell. If tracing is disabled or `LANGSMITH_TRACING` is unset, the script runs the agent locally and reports that uploads are disabled.

## Try a small test

```bash
uv run load-test --users 1 --duration-seconds 30 --run-limit 10 --pause-seconds 1
```

The first `uv run` creates `.venv` in this folder and installs the dependencies. This test stops starting new traces after 10 total attempts or 30 seconds, whichever comes first. Open the project and confirm the traces appear before increasing the load.

## What the agent generates

Each invocation creates a root agent trace with nested model steps. The fake model replies with `ok` and attaches a synthetic JSON output document. Inputs also carry a synthetic JSON document. No tools, retrieval services, or deployed agents are called.

Model replies alternate between including and omitting made-up token counts. Traces include tags, payload-size metadata, and a unique run sequence. Half receive a synthetic feedback rating by default.

After the small test succeeds, increase one setting at a time. For example:

```bash
uv run load-test --users 2 --duration-seconds 60 --run-limit 100 --pause-seconds 1 --feedback-percent 50
```

Two users with a one-second pause produce about two traces per second. More users or a shorter pause increases the rate. Stop increasing when the instance reports upload errors.

Input and output documents use this size mix:

| Share | Size of each document |
| --- | --- |
| 10% | About 1–20 KiB |
| 40% | About 50–250 KiB |
| 40% | About 250–750 KiB |
| 10% | About 1–2 MiB |

Documents contain nested JSON and synthetic text. Two input/output pairs per size range are generated before timing begins and reused during the test. Complete traces include both documents plus child steps, so they can be larger. Reuse affects compression; this workload is not a measurement of unique production data.

## Options

| Option | Default | Meaning |
| --- | --- | --- |
| `--users` | `10` | Concurrent simulated users. |
| `--duration-seconds` | `10` | Time to sustain the test after ramp-up. |
| `--ramp-up-seconds` | `0` | Spread user starts over this interval. |
| `--run-limit` | Unlimited | Maximum total trace attempts across users, including failures. |
| `--pause-seconds` | `0` | Each user's pause between traces. |
| `--simulated-delay-ms` | `0` | Extra local work time before generating each trace. |
| `--feedback-percent` | `50` | Share of traces given synthetic feedback; `0` disables it. |
| `--data-seed` | Random | Repeatable sample documents; concurrent input/output pairing may vary. |
| `--progress-seconds` | `10` | Progress interval; `0` disables updates. |
| `--latency-limit-seconds` | None | Fail if local p95 run time exceeds this limit. |
| `--json` | Off | Print the final summary as JSON; logs go to stderr. |

Increase `--users` gradually while monitoring your instance. The test finishes in-progress attempts, then waits for pending uploads to finish.

## Results

`runs` counts completed attempts, including failures. Run times measure local agent execution, including simulated delay, rather than how long LangSmith takes to store a trace. `run_errors`, `feedback_errors`, and `upload_errors` report local failures and upload failures reported by the SDK. One upload error can affect an entire batch.

Exit code `0` means no reported failures, `1` means a run/feedback/upload failure or a breached latency limit, and `2` means invalid settings or a setup/flush failure. The summary includes the first reported error.

A successful exit means the SDK finished sending its queued uploads without reporting an error. Confirm the project contents before relying on the results.

## Files

- `src/loadtest/cli.py`: command-line options and LangSmith connection.
- `src/loadtest/runner.py`: user scheduling, feedback, and results.
- `src/loadtest/echo_agent.py`: the local agent and dummy model replies.
- `src/loadtest/payloads/`: synthetic document generation and size ranges.

See [self-hosted API setup](https://docs.langchain.com/langsmith/self-host-usage) and [API keys and workspace selection](https://docs.langchain.com/langsmith/create-account-api-key).

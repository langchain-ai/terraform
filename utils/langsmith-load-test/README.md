# LangSmith load test

> The load test has not yet run against a live instance, so no plan has been checked end to end.

Sends a self-hosted LangSmith instance the load a sizing plan was sized for, reads it back, and checks the
two things a plan promises: how long a sent run takes to become readable, and whether every run sent is
stored. It calls no model provider, so it incurs no model charges; your usual infrastructure costs apply.

It is the last step of the loop in [`../langsmith-sizing`](../langsmith-sizing/README.md): size, deploy,
load test, compare. That package writes the load profile this tool reads (payload mix, runs a trace,
feedback, read rate and read mix, targets), so the load exists once, in its `params.yaml`. The load test
needs neither `helm` nor a chart.

## Set up

You need Python 3.11+, [uv](https://docs.astral.sh/uv/getting-started/installation/) 0.13.4 or later, and
an API key for the instance. `helm` and a chart pull are needed only by `langsmith-sizing`, not here. From this folder:

```bash
cp .env.example .env     # then edit it
```

| Setting | What to enter |
| --- | --- |
| `LANGSMITH_TRACING` | `true` to upload traces. `false` generates payloads locally, with no uploads or feedback. |
| `LANGSMITH_ENDPOINT` | Your self-hosted API URL, such as `https://langsmith.example.com/api/v1`. |
| `LANGSMITH_API_KEY` | A key created in the target instance that can create projects, traces and feedback. |
| `LANGSMITH_PROJECT` | The project to create or reuse, such as `load-test`. |
| `LANGSMITH_WORKSPACE_ID` | The workspace ID from **Settings > General**. Set it only when the key can access several workspaces. |

The key identifies the organization and the workspace ID selects the workspace within it; no organization
ID is needed. Keep `.env` private: the script loads it from this folder, and its values take precedence
over the same names exported in your shell. When tracing is enabled the script prints the resolved project
and workspace before it starts.

Use a project that only this test writes to: project statistics and trace listings cover the whole
project, and the heavy filter and the stored count filter on the test's id.

## Run it

A small test first. It stops after 10 traces or 30 seconds; open the project and confirm the traces appear
before you raise the load.

```bash
uv run load-test --users 1 --duration-seconds 30 --run-limit 10 --pause-seconds 1
```

Then verify a plan. From `../langsmith-sizing`, `make profile PRESET=production` writes
`out/load-profile.json` (or `make wizard`, which writes it with the rest), and:

```bash
uv run load-test --profile ../langsmith-sizing/out/load-profile.json --read \
  --duration-seconds 600 --ramp-up-seconds 60 --results results.json
```

`--peak` sends the profile's peak rate instead of its average. `--traces-per-second 50` sends the model's
default load at a rate you choose, with no profile. From the sizing folder, `make load` runs the profile
form and `make compare` reads the results against the plan.

The first `uv run` creates `.venv` here and installs the dependencies.

## What it sends

Each trace is a root run with child runs, `runs_per_trace` of them (a fractional value alternates, so 7.5
gives 7 and 8), built directly with the SDK's `RunTree`. Each run draws a size from the payload mix, by
default 70% small (4 KiB in, 4 out), 25% medium (32, 32) and 5% large (750, 750), from Dzmitry Dubarau's
trace payload measurements. Its input and output are fresh text of that size, so storage and compression
behave like unique data. The text comes from a 10,000-word vocabulary with English's Zipf frequency,
seeded by `--data-seed`; `tests/test_text.py` holds its zlib compression ratio to a band for English
prose. Every run carries the test's unique id in its metadata.

Feedback is `feedback_per_trace` writes a trace (default 0.5, and it can exceed one), spread evenly. It is
sent from its own threads so a slow server does not slow the trace schedule, and drained after the load.

## Rate mode and users mode

- **Rate mode** (`--traces-per-second X`, or `--profile`, whose rate is its average) starts traces on a
  schedule whatever happens to earlier ones (open loop). `--ramp-up-seconds` raises the rate from zero to
  X linearly. `--max-in-flight` caps unfinished traces: a start due over the cap is dropped and counted,
  never delayed. The results report the achieved rate, the schedule lag (how late each start was) and the
  dropped starts, so a generator that cannot keep up shows as lag and drops, not as a lower rate hidden in
  the average. One process generates about 70 MiB of text a second at the default mix, roughly 70 traces
  a second; beyond that run several processes against the same project.
- **Users mode** (`--users N`, the default when no rate is given) is a closed loop: each user starts its
  next trace after the last finishes. Its offered rate falls as the server slows, so it measures a
  server's capacity, not a plan.

## Reads

`--read` sends reads at the profile's `read.requests_per_second` (or `--reads-per-second`), each class
drawn by its weight in `read.mix`, from the same open-loop scheduler. Three of the classes (`list_traces`, `read_trace`, `heavy_filter`), and the lag polls, use the pinned
`langsmith` 0.14.0 SDK's v2 resources (`/api/v2/traces/query`, `/api/v2/traces/{trace_id}/runs`,
`/api/v2/runs/query`), so the instance must serve those endpoints; an instance that does not answers not
found, and those reads count as errors.

| Class | SDK call | Exercises |
| --- | --- | --- |
| `list_traces` | `client.traces.query(project_id, min_start_time, page_size=20)` | query |
| `read_trace` | `client.traces.list_runs(trace_id, project_id, ...)` on a trace sent at least `--read-min-age-seconds` ago | query |
| `project_stats` | `client.read_project(project_id, include_stats=True)` | stats-query |
| `feedback_stats` | `client.get_run_stats(project_ids, is_root=True, filter=feedback_key)` | stats-query |
| `heavy_filter` | `client.runs.query(project_ids, filter=<test id>, min_start_time=now - heavy_window_days)` | query |

The SDK has no feedback-statistics method, so `feedback_stats` uses the run-statistics endpoint over runs
that carry the test's feedback key. Results give each class's count, errors, skipped (a `read_trace` with
no old enough trace yet), p50, p95 and p99.

## Lag and loss

`--lag-sample` (default 5%) marks that share of traces. Each is polled every `--lag-poll-seconds`
(`client.runs.query` by id) until it is readable or `--lag-deadline-seconds` passes. The lag runs from the
moment the test starts sending the trace, so SDK batching counts, and it is an upper bound within one poll
interval. The report gives p50, p95, p99 and max, and the count never readable by the deadline.

After the load the SDK is flushed, then the test counts runs stored for its id (`client.get_run_stats`)
every few seconds until they reach runs sent or `--settle-seconds` ends. Runs sent minus runs stored is the
missing count. A count that cannot be read is reported as unknown and fails the run.

## Targets, results and exit codes

The profile's targets (the model's `slo.*` without a profile) are checked: the lag p99 against
`stored_within_seconds.p99` (more than 1% never readable fails it) and the `read_trace` p99 against
`trace_load_seconds.p99`. A target with nothing measured, such as the read target without `--read`, is "not
measured" and does not fail the run.

`--results FILE` writes schema `langsmith-load-results/1`: the profile used, the settings, achieved write
rate, errors, feedback, reads per class, lag, sent, stored and missing, the verdicts, and the start and end
times. Every field, with its type, unit and meaning, is in [docs/results-fields.md](docs/results-fields.md). `--json` prints it to stdout with logs on stderr. `langsmith-sizing compare` sets it against the plan.

| Exit | Meaning |
| --- | --- |
| `0` | every measured target met, nothing missing, no errors |
| `1` | a failed target, missing runs, a run, feedback, upload or read error, a stored count that could not be read, or a breached `--latency-limit-seconds` (the p95 time to hand a trace to the SDK) |
| `2` | invalid settings or a setup failure |

## Options

`uv run load-test --help` lists every option with its default.

| Group | Options |
| --- | --- |
| load | `--profile`, `--traces-per-second`, `--peak`, `--users`, `--duration-seconds` (10), `--ramp-up-seconds` (0), `--run-limit`, `--max-in-flight` (256), `--pause-seconds` (0), `--simulated-delay-ms` (0), `--feedback-per-trace`, `--data-seed` |
| reads | `--read`, `--reads-per-second`, `--read-min-age-seconds` (60) |
| lag and loss | `--lag-sample` (0.05), `--lag-deadline-seconds` (120), `--lag-poll-seconds` (2), `--settle-seconds` (60) |
| output | `--results`, `--json`, `--latency-limit-seconds`, `--progress-seconds` (10), `--feedback-drain-seconds` (60) |

## Limits

The load test has not yet run against a live instance, so no plan has been checked end to end. One process
generates about 70 traces a second; the stored count reads one project, so use a project only this test writes
to. It sees what a client sees, so it reports no server metric.

## Tests

```bash
uv run python -m unittest discover -s tests
uvx ruff@0.17.3 check src tests
```

Both are offline and need no instance. `make check` in the sizing folder runs them with the sizing gates.

## Files

Every module under `src/loadtest/` is listed here; `tests/test_readme.py` fails when the list and the tree differ.

- `cli.py`: options, profile resolution, connection and summary.
- `profile.py`: the load profile and the model's defaults, read from `langsmith-sizing`.
- `runner.py`: trace sending in both modes, and the report.
- `feedback.py`: feedback on its own threads, drained after the load.
- `schedule.py`: the open-loop scheduler and ramp.
- `draw.py`: the weighted draw of a read class, and the even spread of a fractional count such as feedback a trace.
- `stats.py`: percentiles by nearest rank.
- `reads.py`: the read classes.
- `lag.py`: the send-to-readable lag.
- `verify.py`: runs stored against runs sent.
- `results.py`: the results document and target verdicts.
- `fields.py`: the unit and meaning of every results field; [docs/results-fields.md](docs/results-fields.md) is generated from it (`make reference` in `../langsmith-sizing`).
- `payloads/`: payload sizes from the mix and the English-like text.

## Credits

Hari Narayan wrote this tool and its feedback design. The payload model and its
measurements are Dzmitry Dubarau's, read through `langsmith-sizing`; his review capped
the feedback threads. The read mix and heavy filter are Reed Bender's, and the targets Ben Nagengast's, as
recorded in `langsmith-sizing/params.yaml`.

See [self-hosted API setup](https://docs.langchain.com/langsmith/self-host-usage) and
[API keys and workspace selection](https://docs.langchain.com/langsmith/create-account-api-key).

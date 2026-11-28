# Presets

A preset is a named load, not a size. It states the inputs (users, the busiest trace rate, the average, runs
a trace, where each store runs, whether the install survives a node loss), each with a note saying why,
and `langsmith-sizing` computes the plan from it like from any load a person gives. A flag replaces the
preset's value for that input. A preset is refused at load without its busiest rate and its average, with a
key the model does not have, or with an input that has no note.

The busiest rate is the scale guide's "up to 10, 100, 1,000 traces submitted per second". The average is
that rate over the model's peak factor of 3. At the model's 10 runs a trace, 1 trace/s is 10 runs/s.

The regime is the model's band for the load ([how it sizes](../docs/how-it-sizes.md#2-regime)); it decides which
parts of the plan turn on. Both charts in [charts.yaml](../charts.yaml) give the same regime for every
preset. On the newer line, called 0.18 below, whose chart can run SmithDB as one unified pod, `extra-lite`
and `minimum` do.

Every figure below is a plan regenerated with `uv run langsmith-sizing size --preset <name> --chart <version>`
for each version in `charts.yaml`, 0.17 being its older line. vCPU is requested, before the node overhead
factor, at the autoscalers' floors and at the sized replicas.

| Preset | Meant for | Load it states (busiest / average traces/s, users) | Regime and SmithDB | vCPU at floors / sized | Open question |
|:--|:--|:--|:--|:--|:--|
| `extra-lite` | The smallest install that runs: one node, every store in the cluster, serving pods at one replica, 7 days of retention. Does not survive the loss of its node. | 3 / 1, 2 users | `extra-lite`; SmithDB `small` as five pods on 0.17, one unified pod on 0.18 | 23.8 / 23.8 on 0.17, 9.5 / 9.5 on 0.18 | It does not fit one 8 vCPU / 32 GiB node with the largest hook Job: that peak is 28.9 vCPU and 68.5 GiB after overhead on 0.17, 11.8 vCPU and 44.2 GiB on 0.18 (the plan warns `single-node-hook-peak`). It also opens 259 Postgres connections against a budget of 80. |
| `minimum` | Cost parking, idle standby, smoke tests, single-user demos, with managed stores. | 1 / 0.3, 1 user | `extra-lite`; SmithDB `small` as five pods on 0.17, one unified pod on 0.18 | 19.3 / 19.3 on 0.17, 5.0 / 5.0 on 0.18 | On 0.17 the hook peak, 23.5 vCPU and 50.1 GiB after overhead, does not fit one 8 vCPU / 32 GiB node. On 0.18 it fits (6.4 vCPU, 25.8 GiB), so what remains open is that no load test has read it. |
| `lite` | Two nodes and the smallest managed Postgres, Redis and object store, up to about 15 traces/s. | 15 / 5, 5 users | `lite`; SmithDB `small`, two ingestion pods | 34.2 / 36.2 | Its 150 peak runs/s is past the small band's 100, which alone plans SmithDB as `medium` (104 vCPU at the floors); the regime keeps `small` with two ingestion pods at the 86 runs/s one pod was measured to hold. One unified pod does not carry 150 runs/s, so it stays five pods on 0.18 too. The 34.2 vCPU is more than two 8 vCPU nodes hold, and 15 traces/s is unmeasured until a load test proves it. |
| `dev` | Development, integration tests, demos with a developer using the system: the guide's Low load. | 10 / 3.3, 5 users | `lite`; SmithDB `small`, two ingestion pods | 34.2 / 34.2 | The same layout as `lite` from its 100 peak runs/s. |
| `production` | Real traffic, surviving the loss of a node: the guide's Medium load. | 100 / 33, 20 users | `large`; SmithDB `large` | 491.0 / 515.0 | The guide calls this load Medium and the regime `standard`, but 100 traces/s at 10 runs a trace is 1,000 runs/s, exactly the large band's edge, where the larger regime wins. The module's `production` profile reserves 13.7 to 22.7 vCPU (the Core and Full rows of the Quick Comparison table in `modules/aws/helm/values/examples/SIZING.md`, rendered at chart 0.16.34): do not read it as the plan's equal. |
| `production-large` | The guide's High load. | 1,000 / 333, 50 users | `scale-out`; SmithDB `large` | 470.0 / 591.0 | 1,000 traces/s at 10 runs a trace is 10,000 peak runs/s, the large band's top, so the plan is `scale-out`, not `large`. It warns `beyond-payload-tested` and `beyond-tiers`, and needs a Redis cluster and a Postgres connection plan. Treat it as a starting point for a conversation, not a size. |

No preset has been run against a live install, so every one carries an open question.

The four names `minimum`, `dev`, `production` and `production-large` are also the modules' hand-written
sizing profiles, which the modules still deploy. `make report` covers those four, not all six, because only
they have a module profile: it prints each preset's plan beside each module's profile and marks every figure
that differs.

The figures move with the chart and the parameters. `tests/test_presets.py` asserts the regimes of
`extra-lite`, `minimum`, `lite` and `dev`, and records three of the six open questions (`extra-lite`,
`production`, `production-large`) as expected failures.

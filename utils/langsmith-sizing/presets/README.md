# Presets

A preset is a named load, not a size. It states the inputs (users, the busiest trace rate, the average, runs
a trace, where each store runs, whether the install survives a node loss), each with a note saying why,
and `langsmith-sizing` computes the plan from it like from any load a person gives. A flag replaces the
preset's value for that input. A preset is refused at load without its busiest rate and its average, with a
key the model does not have, or with an input that has no note.

The busiest rate is the scale guide's "up to 10, 100, 1,000 traces submitted per second". The average is
that rate over the model's peak factor of 3. At the model's 10 runs a trace, 1 trace/s is 10 runs/s.

The regime is the model's band for the load (see [how it sizes](../docs/how-it-sizes.md#2-regime)); it decides which
parts of the plan turn on. The chart versions the package plans for ([charts.yaml](../charts.yaml): 0.17.56 and
0.18.0-rc.79) give the same regime for every preset; on 0.18, whose chart can run SmithDB as one unified pod,
`extra-lite` and `minimum` do.

| Preset | Meant for | Load it states (busiest / average traces/s, users) | Regime and SmithDB, 0.17.56 / 0.18.0-rc.79 | Open question |
|:--|:--|:--|:--|:--|
| `extra-lite` | The smallest install that runs: one node, every store in the cluster, serving pods at one replica, 7 days of retention. Does not survive the loss of its node. | 3 / 1, 2 users | `extra-lite`; SmithDB `small` as five pods / one unified pod | It does not fit one 8 vCPU / 32 GiB node at chart-default requests: the pods, stores and the largest hook Job ask for 38.1 vCPU and 100.1 GiB after overhead on 0.17.56, and 21.0 vCPU and 75.8 GiB with the unified pod on 0.18 (the plan warns `single-node-hook-peak`). It also opens 259 Postgres connections against a budget of 80. |
| `minimum` | Cost parking, idle standby, smoke tests, single-user demos, with managed stores. | 1 / 0.3, 1 user | `extra-lite`; SmithDB `small` as five pods / one unified pod | The single-node hook-peak defect: 30.6 vCPU and 60.5 GiB after overhead on 0.17.56, 13.5 vCPU and 36.2 GiB on 0.18, against one 8 vCPU / 32 GiB node. |
| `lite` | Two nodes and the smallest managed Postgres, Redis and object store, up to about 15 traces/s. | 15 / 5, 5 users | `lite`; SmithDB `small`, two ingestion pods | Its 150 peak runs/s is past the small band's 100, which planned SmithDB as `medium` (104 vCPU at the floors); the regime keeps `small` with two ingestion pods at the 86 runs/s one pod was measured to hold, 34.2 vCPU at the floors. One unified pod does not carry 150 runs/s, so it stays five pods on 0.18 too. Two 8 vCPU nodes still do not hold it, and the 15 traces/s is unmeasured until a load test proves it. |
| `dev` | Development, integration tests, demos with a developer using the system: the guide's Low load. | 10 / 3.3, 5 users | `lite`; SmithDB `small`, two ingestion pods | The same layout as `lite` from its 100 peak runs/s, 34.2 vCPU at the floors. |
| `production` | Real traffic, surviving the loss of a node: the guide's Medium load. | 100 / 33, 20 users | `large`, SmithDB `large` | The guide calls this load Medium and the regime `standard`, but 100 traces/s at 10 runs a trace is 1,000 runs/s, exactly the large band's edge, where the larger regime wins. It plans at 491 vCPU of requests at the autoscalers' floors (515 sized) against 13.7 to 22.7 vCPU reserved in the AWS module's `production` profile (the Core and Full rows of the Quick Comparison table in `modules/aws/helm/values/examples/SIZING.md`, rendered at chart 0.16.34). Do not read the module's profile as the plan's equal. |
| `production-large` | The guide's High load. | 1,000 / 333, 50 users | `beyond-tested`, SmithDB `large` | 10,000 peak runs/s is the last band's edge. The plan warns `beyond-tested` (the payload measurements stop at 300 traces/s) and `beyond-tiers`; it needs a Redis cluster and 603 vCPU of requests at the floors (852 sized). Treat it as a starting point for a conversation, not a size. |

All six presets carry an open question: none is proven.

The four names `minimum`, `dev`, `production` and `production-large` are also the modules' hand-written
sizing profiles, which the modules still deploy. `make report` (in the package folder) covers those four, not
all six, because only they have a module profile: it prints each preset's plan beside each module's profile
and marks every figure that differs.

Figures are the plans at charts 0.17.56 and 0.18.0-rc.79 when this table was last checked, and move with the chart
and the parameters. `tests/test_presets.py` asserts the regimes of `extra-lite`, `minimum`, `lite` and `dev`, and
records three of the six open questions above as expected failures.

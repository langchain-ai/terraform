"""The sizing model: pure functions, numbers in and numbers out.

Nothing here reads a file, the network or the chart. Every function takes the inputs, the params,
the cited docs values and the chart-derived numbers it needs as arguments, so a test can hold each
one to its worked example and `plan.size` is the only place that gathers them.

  load      rates, load bands, the scale guide's grid and the interpolation between its corners
  payload   the payload mix and the per-run curves
  services  application replicas, the ingest queue and Go pods
  smithdb   the tier by peak runs a second and by reads, the read model, splits, metastore
  stores    Redis, Postgres connections, object storage, ClickHouse while dual
"""

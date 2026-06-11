# Changelog

The per-release history lives in
**[GitHub Releases](https://github.com/langchain-ai/terraform/releases)**, which
are created automatically on every merge to `main` by
[`.github/workflows/release.yml`](.github/workflows/release.yml). This file is not
maintained by hand.

## Versioning

Releases are global tags `vMAJOR.MINOR.PATCH`:

- `MAJOR.MINOR` tracks the supported LangSmith Helm chart line. `deploy.sh`
  installs the latest patch within that line (`~0.15.1` => latest `0.15.x`,
  never `0.16`).
- `PATCH` is a module revision counter. It increments on any change to this
  repo, regardless of provider, and is **not** the chart version (`v0.15.4`
  does not mean chart `0.15.4`).

Deploy from a tag (`git checkout v0.15.0`), never from `main`.

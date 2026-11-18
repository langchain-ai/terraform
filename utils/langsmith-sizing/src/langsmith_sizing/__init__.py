"""Size and autoscale a self-hosted LangSmith install from its load.

Every number comes from one of five places, and only one of them is this package's own:
  chart      read from the LangSmith Helm chart at the version planned (chart.py), never copied
  docs       cited from langchain-ai/docs by commit and quote, checked (citations.py)
  inputs     what the person says about their load and install
  measured   what a running install reports; compared with a plan, never stored here
  params     the model's own constants, each with its evidence (params.yaml, params.py)
"""

from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parent.parent.parent
_CHARTS = yaml.safe_load((ROOT / "charts.yaml").read_text())
PLANNED_CHARTS: tuple[str, ...] = tuple(str(v) for v in _CHARTS["planned"])

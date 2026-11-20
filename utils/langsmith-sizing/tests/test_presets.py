import contextlib
import io
import json
import tempfile
import unittest
from pathlib import Path

from langsmith_sizing import PLANNED_CHARTS, cli, params, plan, presets
from tests.helpers import CHART, CITED, P, chart_at, chart_or_skip, needs_helm, size

GOOD = """why: "a test load"
inputs:
  users: 3
  peak_traces_per_second: 9
  traces_per_second: 3
notes:
  users: "u"
  peak_traces_per_second: "p"
  traces_per_second: "t"
"""
NAMES = ["dev", "extra-lite", "lite", "minimum", "production", "production-large"]
NEXT = PLANNED_CHARTS[-1]


def _dir(text: str) -> Path:
    d = Path(tempfile.mkdtemp()) / "presets"
    d.mkdir()
    (d / "x.yaml").write_text(text)
    return d


class Loading(unittest.TestCase):
    def test_the_six_presets_load(self) -> None:
        self.assertEqual(presets.names(), NAMES)
        for n in presets.names():
            self.assertEqual(presets.load(n).name, n)

    def test_a_good_preset_loads(self) -> None:
        p = presets.load("x", _dir(GOOD))
        self.assertEqual(p.inputs["users"], 3)
        self.assertEqual(p.to_inputs(CHART).peak_traces_per_second, 9)

    def test_a_preset_without_a_rate_is_refused(self) -> None:
        for gone in ("peak_traces_per_second", "traces_per_second"):
            text = "\n".join(line for line in GOOD.splitlines() if not line.startswith(f"  {gone}:"))
            with self.assertRaisesRegex(presets.PresetError, gone):
                presets.load("x", _dir(text))

    def test_a_key_inputs_lacks_is_refused(self) -> None:
        text = GOOD.replace("notes:", "  userz: 1\nnotes:", 1).replace('  users: "u"', '  users: "u"\n  userz: "z"')
        with self.assertRaisesRegex(presets.PresetError, "userz"):
            presets.load("x", _dir(text))

    def test_an_input_without_a_note_is_refused(self) -> None:
        with self.assertRaisesRegex(presets.PresetError, "no note for users"):
            presets.load("x", _dir(GOOD.replace('  users: "u"\n', "")))

    def test_an_unknown_preset_names_the_known_ones(self) -> None:
        with self.assertRaisesRegex(presets.PresetError, "production-large"):
            presets.load("nope")

    def test_a_traces_override_replaces_the_average_only(self) -> None:
        i = presets.load("production").to_inputs(CHART, traces_per_month=5e7)
        self.assertEqual((i.traces_per_second, i.traces_per_month, i.peak_traces_per_second), (None, 5e7, 100))


@needs_helm
class Sizing(unittest.TestCase):
    def test_a_rate_that_passes_the_presets_peak_is_refused_until_the_peak_is_given(self) -> None:
        # `--preset production --traces-per-second 200` was a plan with an average of 200 and a peak of 100
        with self.assertRaisesRegex(ValueError, "the peak of 100 traces/s is below the average of 200"):
            plan.size(presets.load("production").to_inputs(CHART, traces_per_second=200), chart_at(), params.load(), CITED)
        sized = plan.size(presets.load("production").to_inputs(CHART, traces_per_second=200, peak_traces_per_second=600), chart_at(), params.load(), CITED)
        self.assertEqual(sized["rates"]["peak_traces_per_second"], 600)

    def regime(self, name: str) -> str:
        return str(size(**vars_of(name))["regime"]["id"])

    def test_the_presets_under_the_busiest_rates_of_a_demo_and_a_dev_team_are_in_the_low_regimes(self) -> None:
        # each regime is the one the preset's own name and why call for: minimum is cost parking and a
        # single-user demo (1 trace/s), extra-lite is the one-node install, lite is the install of up to
        # about 15 traces/s, dev is the scale guide's Low load (up to 10 traces/s, under lite's 15)
        self.assertEqual({n: self.regime(n) for n in ("minimum", "extra-lite", "lite", "dev")}, {"minimum": "extra-lite", "extra-lite": "extra-lite", "lite": "lite", "dev": "lite"})

    @unittest.expectedFailure
    def test_production_is_the_standard_regime_the_scale_guides_medium_load_is(self) -> None:
        # The production preset is the guide's Medium load, up to 100 traces/s, which regime `standard`
        # describes ("the scale guide's configurations"). The bands put its 1,000 peak runs/s on the
        # edge of SmithDB's large band, where "the larger regime wins" (params regimes), so it plans as
        # `large`: Medium-load installs get a Redis cluster, partitions and separate node pools.
        self.assertEqual(self.regime("production"), "standard")

    @unittest.expectedFailure
    def test_production_large_is_the_large_regime_the_guides_high_load_is(self) -> None:
        # The guide publishes its High configuration (up to 1,000 traces/s), so the preset should plan as
        # `large`. At 10 runs a trace its 10,000 peak runs/s reach the large band's top, where `scale-out`
        # starts: the plan treats a load the guide documents as past the docs' tiers.
        self.assertEqual(self.regime("production-large"), "large")

    def test_the_production_presets_survive_a_node_loss(self) -> None:
        for name in ("production", "production-large"):
            plan = size(**vars_of(name))
            floors = [w["min"] for w in plan["workloads"].values()] + [c["min"] for c in plan["smithdb"]["components"].values()]
            self.assertGreaterEqual(min(floors), 2, name)

    def test_the_lab_presets_do_not(self) -> None:
        self.assertEqual(min(w["min"] for w in size(**vars_of("extra-lite"))["workloads"].values()), 1)

    def test_the_lite_preset_runs_the_smallest_smithdb_tier_with_ingestion_scaled_out(self) -> None:
        # Its 150 peak runs/s is past the small band's 100, which once planned SmithDB as `medium`: two
        # 28 vCPU query pods for the smallest install. The regime keeps small and adds ingestion pods at
        # the measured pod capacity; the model's band is kept beside it.
        p = size(**vars_of("lite"))
        s = p["smithdb"]
        need = -(-p["rates"]["runs_per_second_peak"] // P["smithdb.small_ingestion_runs_per_pod"])
        self.assertEqual((s["tier"], s["tier_by"], s["auto"]["tier"]), ("small", "regime", "medium"))
        self.assertEqual(s["components"]["ingestion"]["min"], need)


@needs_helm
class OnOneNode(unittest.TestCase):
    def setUp(self) -> None:
        # outside the expected failure below: a missing chart must fail under REQUIRE_HELM, not pass as one
        chart_or_skip(self, NEXT)

    @unittest.expectedFailure
    def test_the_extra_lite_preset_fits_one_8_vcpu_32_gib_node_on_both_charts(self) -> None:
        # Extra-lite is the install that runs on one node, its pods, stores and Helm's hook Jobs
        # included. With each pod at what the lab measured it to use (lite.measured) it still does not
        # fit: after overhead about 12 vCPU and 44 GiB on 0.18, 29 and 69 on 0.17, which cannot run
        # SmithDB as one pod. Three requests nobody has measured at this load hold it there: the unified
        # SmithDB pod at the chart's 4 vCPU / 16 GiB, the in-cluster object store's 7.2 GiB peak from a
        # far heavier run, and six hours of runs in Redis. The plan says so (single-node-hook-peak).
        for version in (CHART, NEXT):
            single = size(chart_version=version, **{k: v for k, v in vars_of("extra-lite").items()})["pools"]["single_node"]
            self.assertTrue(single["fits"], f"{version}: {single['cpu']:g} vCPU, {single['mem_gib']:g} GiB on {single['node_cpu']:g} x {single['node_mem_gib']:g}")


class Cli(unittest.TestCase):
    def _out(self, *argv: str) -> dict[str, object]:
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            self.assertEqual(cli.main(list(argv)), 0)
        return json.loads(out.getvalue())  # type: ignore[no-any-return]

    @needs_helm
    def test_size_takes_a_preset_and_a_flag_replaces_its_value(self) -> None:
        plan = self._out("size", "--chart", CHART, "--preset", "lite")
        self.assertEqual(plan["inputs"]["users"], 5)  # type: ignore[index]
        again = self._out("size", "--chart", CHART, "--preset", "lite", "--users", "8")
        self.assertEqual(again["inputs"]["users"], 8)  # type: ignore[index]

    @needs_helm
    def test_load_profile_reads_a_preset(self) -> None:
        prof = self._out("load-profile", "--chart", CHART, "--preset", "production")
        self.assertEqual(prof["schema"], "langsmith-load-profile/1")
        self.assertEqual(prof["write"]["peak_traces_per_second"], 100)  # type: ignore[index]
        self.assertEqual(prof["read"]["users"], 20)  # type: ignore[index]

    def test_without_a_preset_users_is_required(self) -> None:
        err = io.StringIO()
        with contextlib.redirect_stderr(err):
            self.assertEqual(cli.main(["size", "--chart", CHART, "--traces-per-second", "5"]), 1)
        self.assertIn("--preset or --users", err.getvalue())


def vars_of(name: str) -> dict[str, object]:
    i = presets.load(name).to_inputs(CHART)
    return {k: v for k, v in vars(i).items() if k != "chart_version"}


if __name__ == "__main__":
    unittest.main()

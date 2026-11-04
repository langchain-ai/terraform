"""Verify the deployment binding against the Kubernetes Service/API boundary."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


class FrontendBindingTest(unittest.TestCase):
    arn = "arn:aws:elasticloadbalancing:us-west-2:123456789012:targetgroup/test/abcdef1234567890"
    script = Path(__file__).with_name("frontend-target-group.sh")

    def bind(self, services, arn=None, existing_arn="", fail_operation=""):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "services.json").write_text(json.dumps({"items": services}))
            (root / "existing-arn").write_text(existing_arn)
            kubectl = root / "kubectl"
            kubectl.write_text('''#!/usr/bin/env bash
set -eu
printf '%s\n' "$*" >> "$FIXTURE_DIR/calls"
case "$1 $2" in
  "get services")
    [[ "$*" == "get services -n custom-ns -l app.kubernetes.io/instance=custom-release -o json" ]]
    cat "$FIXTURE_DIR/services.json"
    ;;
  "get targetgroupbinding")
    [[ "$*" == "get targetgroupbinding custom-frontend-alb -n custom-ns --ignore-not-found -o jsonpath={.spec.targetGroupARN}" ]]
    [[ "$FAIL_OPERATION" != "lookup" ]] || exit 1
    cat "$FIXTURE_DIR/existing-arn"
    ;;
  "delete targetgroupbinding")
    [[ "$*" == "delete targetgroupbinding custom-frontend-alb -n custom-ns --wait=true --timeout=120s" ]]
    [[ "$FAIL_OPERATION" != "delete" ]] || exit 1
    rm "$FIXTURE_DIR/existing-arn"
    ;;
  "apply -f")
    [[ "$*" == "apply -f -" ]]
    cat > "$FIXTURE_DIR/applied.json"
    ;;
  *) exit 1 ;;
esac
''')
            kubectl.chmod(0o755)
            result = subprocess.run(
                ["bash", str(self.script), arn or self.arn, "custom-ns", "custom-release"],
                env={**os.environ, "PATH": f"{root}:{os.environ['PATH']}", "FIXTURE_DIR": str(root),
                     "FAIL_OPERATION": fail_operation},
                capture_output=True, text=True,
            )
            calls = root / "calls"
            self.calls = calls.read_text().splitlines() if calls.exists() else []
            applied = root / "applied.json"
            return result, json.loads(applied.read_text()) if applied.exists() else None

    @staticmethod
    def service(name="custom-frontend", service_type="ClusterIP"):
        return {"metadata": {"name": name, "uid": "service-uid"},
                "spec": {"type": service_type,
                         "ports": [{"name": "http", "port": 80, "targetPort": "frontend"}]}}

    def test_binding_tracks_actual_service_and_its_lifecycle(self):
        unrelated = {"metadata": {"name": "backend"}, "spec": {"ports": [{"port": 1984}]}}
        result, binding = self.bind([unrelated, self.service()])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(binding["kind"], "TargetGroupBinding")
        self.assertEqual(binding["metadata"]["namespace"], "custom-ns")
        self.assertEqual(binding["metadata"]["ownerReferences"],
                         [{"apiVersion": "v1", "kind": "Service", "name": "custom-frontend", "uid": "service-uid"}])
        self.assertEqual(binding["spec"], {"serviceRef": {"name": "custom-frontend", "port": "http"},
                                           "targetGroupARN": self.arn, "targetType": "ip"})

    def test_changed_target_group_recreates_binding_before_apply(self):
        result, binding = self.bind(
            [self.service()], existing_arn=self.arn.replace("/test/", "/previous/"))
        self.assertEqual(result.returncode, 0, result.stderr)
        delete = ("delete targetgroupbinding custom-frontend-alb "
                  "-n custom-ns --wait=true --timeout=120s")
        self.assertIn(delete, self.calls)
        self.assertLess(self.calls.index(delete), self.calls.index("apply -f -"))
        self.assertEqual(binding["spec"]["targetGroupARN"], self.arn)

    def test_unchanged_target_group_keeps_binding(self):
        result, binding = self.bind([self.service()], existing_arn=self.arn)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(any(call.startswith("delete ") for call in self.calls))
        self.assertEqual(binding["spec"]["targetGroupARN"], self.arn)

    def test_binding_api_failures_stop_before_apply(self):
        for operation in ("lookup", "delete"):
            with self.subTest(operation=operation):
                result, binding = self.bind(
                    [self.service()], existing_arn=self.arn.replace("/test/", "/previous/"),
                    fail_operation=operation)
                self.assertNotEqual(result.returncode, 0)
                self.assertIsNone(binding)
                if operation == "lookup":
                    self.assertFalse(any(call.startswith("delete ") for call in self.calls))

    def test_missing_or_ambiguous_service_does_not_apply(self):
        for services in ([], [self.service(), self.service("second-frontend")]):
            with self.subTest(services=services):
                result, binding = self.bind(services)
                self.assertNotEqual(result.returncode, 0)
                self.assertIsNone(binding)

    def test_load_balancer_service_does_not_apply(self):
        result, binding = self.bind([self.service(service_type="LoadBalancer")])
        self.assertNotEqual(result.returncode, 0)
        self.assertIsNone(binding)

    def test_missing_infrastructure_output_does_not_apply(self):
        result, binding = self.bind([self.service()], arn="null")
        self.assertNotEqual(result.returncode, 0)
        self.assertIsNone(binding)


class PermutationConfigurationTest(unittest.TestCase):
    def test_helm_steps_read_the_permutation_overrides_and_base_settings(self):
        aws_dir = Path(__file__).resolve().parents[2]
        common = aws_dir / "infra/scripts/_common.sh"
        source = (aws_dir / "infra/scripts/test-permutations.sh").read_text()
        start = source.index("_helm_deploy() {")
        function = source[start:source.index("\n}\n", start) + 3]
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "scripts").mkdir()
            (root / "terraform.tfvars").write_text(
                'enable_deployments = true\ntls_certificate_source = "acm"\n'
                'region = "us-west-2"\nlangsmith_domain = "original.example.com"\n')
            probe = ("#!/usr/bin/env bash\nset -euo pipefail\n"
                     'source "$COMMON_SCRIPT"\n'
                     'for key in enable_deployments tls_certificate_source region langsmith_domain; do\n'
                     '  printf "%s=%s\\n" "$key" "$(_parse_tfvar "$key")"\n'
                     'done\n')
            for name in ("init-values.sh", "deploy.sh"):
                path = root / "scripts" / name
                path.write_text(probe)
                path.chmod(0o755)
            override = root / "permutation.auto.tfvars"
            for tls in ("none", "acm"):
                with self.subTest(tls=tls):
                    override.write_text(
                        f'enable_deployments = false\ntls_certificate_source = "{tls}"\n'
                        'langsmith_domain = "permutation.example.com"\n')
                    log = root / "deploy.log"
                    log.write_text("")
                    env = {**os.environ, "COMMON_SCRIPT": str(common),
                           "INFRA_DIR": str(root), "HELM_DIR": str(root),
                           "OVERRIDE_FILE": str(override), "DRY_RUN": "false"}
                    result = subprocess.run(
                        ["bash", "-c", 'set -euo pipefail\n_step(){ :; }\n_ok(){ :; }\n'
                         + function + '\n_helm_deploy "$1"', "test", str(log)],
                        env=env, capture_output=True, text=True)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    expected = (f"enable_deployments=false\ntls_certificate_source={tls}\n"
                                "region=us-west-2\nlangsmith_domain=permutation.example.com\n")
                    self.assertEqual(log.read_text(), expected * 2)


if __name__ == "__main__":
    unittest.main()

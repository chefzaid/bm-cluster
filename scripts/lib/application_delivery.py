"""Project-scoped runners and Kubernetes admission for environment-aware delivery.

Only trusted platform code constructs runner pods and permissions. Application
branches may change their CI scripts, but cannot obtain a release runner token
or turn their integration Application into a production deployment.
"""
import base64
import copy
import hashlib
import json
from pathlib import Path
import re
from urllib.parse import quote

import yaml

from onboarding_services import HTTP, HTTPFailure, ServiceError

ROOT = Path(__file__).resolve().parents[2]
NAMESPACE = "gitlab-runners"
MANAGER = "bm-cluster-application-delivery"
TAGS = {"int": "bm-application-int", "release": "bm-application-release"}


def resource(kind, name, namespace=None, api="v1", **fields):
    metadata = {"name": name, "labels": {"app.kubernetes.io/managed-by": MANAGER}}
    if namespace:
        metadata["namespace"] = namespace
    return {"apiVersion": api, "kind": kind, "metadata": metadata, **fields}


class ApplicationDelivery:
    def __init__(self, environments):
        self.environments = environments
        self.api = environments.onboarding.api
        self.kubectl = environments.onboarding.kubectl
        self.context = environments.context
        self.project = str(self.context["GITLAB_PROJECT_ID"])
        self.app = environments.name
        if not re.fullmatch(r"[1-9][0-9]*", self.project):
            raise ServiceError("Application delivery requires a numeric GitLab project identity")
        self.name = "gitlab-project-" + self.project
        self.owner = self.context["GITLAB_PROJECT_PATH"]
        self.system_id = "r_" + hashlib.sha256((self.project + ":" + self.owner).encode()).hexdigest()[:12]

    def get(self, kind, name, namespace=NAMESPACE):
        args = ["get", kind, name, "--ignore-not-found", "-o", "json"]
        if namespace:
            args.extend(["-n", namespace])
        return self.kubectl(*args)

    def apply(self, document):
        document["metadata"].setdefault("annotations", {})["bm-cluster.io/gitlab-project"] = self.owner
        self.kubectl("apply", "--server-side", "--field-manager=" + MANAGER, "-f", "-", resource=document)

    def require_owned(self, document):
        if document and document.get("metadata", {}).get("annotations", {}).get("bm-cluster.io/gitlab-project") != self.owner:
            raise ServiceError("A delivery resource belongs to another project; explicit migration is required")

    def project_settings(self):
        project = self.api.call("GET", "projects/" + self.project)
        branch = self.api.call("GET", f"projects/{self.project}/repository/branches/" + quote(project["default_branch"], safe=""))
        if not branch.get("protected"):
            raise ServiceError("Protect the default branch before enabling release delivery")
        runners = self.api.call("GET", f"projects/{self.project}/runners?type=project_type&per_page=100")
        if len(runners) >= 100:
            raise ServiceError("Too many project runners to reconcile safely")
        expected = {self.name + "-" + lane for lane in TAGS}
        if (project.get("shared_runners_enabled") or project.get("group_runners_enabled") or
                any(item.get("description") not in expected for item in runners)):
            self.require_idle()
        return project

    def require_idle(self):
        jobs = self.api.call("GET", f"projects/{self.project}/jobs?scope[]=running&scope[]=pending&per_page=1")
        if jobs:
            raise ServiceError("Finish or cancel existing project jobs before changing delivery runners or their credentials")

    def permissions(self):
        documents = []
        for lane in TAGS:
            name = self.name + "-" + lane
            targets = {env: target for env, target in self.environments.targets.items() if lane == "release" or env == "int"}
            documents.append(resource("ServiceAccount", name, NAMESPACE, automountServiceAccountToken=True))
            rules = [{"apiGroups": [""], "resources": ["configmaps"],
                      "resourceNames": ["deployment-environments"], "verbs": ["get"]}]
            if targets:
                rules.append({"apiGroups": ["argoproj.io"], "resources": ["applications"],
                              "resourceNames": [self.app + "-" + env for env in targets],
                              "verbs": ["get", "patch", "update"]})
            documents.append(resource("Role", name, "infra", api="rbac.authorization.k8s.io/v1", rules=rules))
            documents.append(resource("RoleBinding", name, "infra", api="rbac.authorization.k8s.io/v1",
                roleRef={"apiGroup": "rbac.authorization.k8s.io", "kind": "Role", "name": name},
                subjects=[{"kind": "ServiceAccount", "name": name, "namespace": NAMESPACE}]))
            allowed = []
            for env, target in targets.items():
                allowed.append("(" + " && ".join([
                    "object.metadata.name == " + json.dumps(self.app + "-" + env),
                    "object.spec.project == " + json.dumps(target["project"]),
                    "object.spec.destination.name == " + json.dumps(target["clusterName"]),
                    "object.spec.destination.namespace == 'apps'",
                    "!has(object.spec.destination.server)",
                    "object.spec.source.path == " + json.dumps("infra/environments/" + env),
                ]) + ")")
            expression = " && ".join([
                "!(has(object.spec.sources))", "has(object.spec.source)",
                "object.spec.source.repoURL == " + json.dumps(self.context["GITLAB_REPOSITORY_URL"]),
                "object.spec.source.targetRevision.matches('^[0-9a-f]{40}$')",
                "(!has(object.operation) || object.operation == null || "
                "(oldObject != null && has(oldObject.operation) && object.operation == oldObject.operation))",
                "(" + (" || ".join(allowed) or "false") + ")",
            ])
            documents.append(resource("ValidatingAdmissionPolicy", name, api="admissionregistration.k8s.io/v1", spec={
                "failurePolicy": "Fail", "matchConstraints": {"resourceRules": [{"apiGroups": ["argoproj.io"],
                    "apiVersions": ["v1alpha1"], "operations": ["CREATE", "UPDATE"], "resources": ["applications"]}]},
                "matchConditions": [{"name": "delivery-service-account", "expression":
                    "request.userInfo.username == " + json.dumps(f"system:serviceaccount:{NAMESPACE}:{name}")}],
                "validations": [{"expression": expression,
                    "message": "Delivery must retain its registered application, environment, repository and immutable revision."}]}))
            documents.append(resource("ValidatingAdmissionPolicyBinding", name, api="admissionregistration.k8s.io/v1",
                spec={"policyName": name, "validationActions": ["Deny"]}))
        return documents

    def prepare_applications(self):
        if not self.environments.targets:
            return
        template = yaml.safe_load((self.environments.checkout.root / self.environments.contract["application"]).read_text())
        revision = self.environments.checkout.git("rev-parse", "HEAD")
        if not re.fullmatch(r"[0-9a-f]{40}", revision):
            raise ServiceError("Application bootstrap requires its published configuration commit")
        for env, target in self.environments.targets.items():
            name = self.app + "-" + env
            existing = self.get("application", name, "infra")
            expected = {"project": target["project"], "destination": {"name": target["clusterName"], "namespace": "apps"}}
            source = {"repoURL": self.context["GITLAB_REPOSITORY_URL"], "path": "infra/environments/" + env}
            if existing:
                spec = existing.get("spec", {})
                if (any(spec.get(key) != value for key, value in expected.items()) or
                        any(spec.get("source", {}).get(key) != value for key, value in source.items()) or spec.get("sources")):
                    raise ServiceError("An existing Application belongs to another delivery target or repository")
                continue
            app = resource("Application", name, "infra", api="argoproj.io/v1alpha1",
                spec={**expected, "source": {**source, "targetRevision": revision},
                      "syncPolicy": {key: value for key, value in template["spec"].get("syncPolicy", {}).items() if key != "automated"}})
            # No automated sync: the first CI publication supplies runtime files
            # and enables reconciliation. Jobs never receive Application create.
            self.apply(app)

    def runner_resources(self):
        baseline = list(yaml.safe_load_all((ROOT / "k8s/platform/gitlab-runner.yaml").read_text()))
        config = next(item["data"]["config.template.toml"] for item in baseline if item["kind"] == "ConfigMap" and item["metadata"]["name"] == "gitlab-runner-config")
        prefix, body = config.split("[[runners]]", 1)
        # Branch and release jobs never share a writable cache volume. GitLab
        # artifacts carry verified build outputs between jobs instead.
        body = body.split("[[runners.kubernetes.volumes.pvc]]", 1)[0]
        body += '\n    [[runners.kubernetes.volumes.empty_dir]]\n      name = "cache"\n      mount_path = "/cache"\n'
        blocks = []
        for lane in TAGS:
            block = body.replace('name = "bm-cluster-kubernetes"', 'name = ' + json.dumps(self.name + "-" + lane))
            block = block.replace('service_account = "gitlab-ci-job"', 'service_account = ' + json.dumps(self.name + "-" + lane))
            block = block.replace("__RUNNER_TOKEN__", "__RUNNER_" + lane.upper() + "_TOKEN__")
            blocks.append("[[runners]]" + block)
        config = (prefix + "\n".join(blocks)).replace("__INTERNAL_DNS_ZONE__", self.context["INTERNAL_DNS_ZONE"])
        config = re.sub(r"(?m)^#.*\n", "", config)
        deployment = copy.deepcopy(next(item for item in baseline if item["kind"] == "Deployment"))
        deployment = json.loads(json.dumps(deployment).replace("__PUBLIC_DOMAIN__", self.context["PUBLIC_DOMAIN"]))
        deployment["metadata"] = resource("Deployment", self.name, NAMESPACE)["metadata"]
        deployment["spec"]["selector"]["matchLabels"] = {"app": self.name}
        pod = deployment["spec"]["template"]
        pod["metadata"]["labels"] = {"app": self.name}
        pod["metadata"]["annotations"]["bm-cluster.io/runner-config"] = hashlib.sha256(config.encode()).hexdigest()
        container = pod["spec"]["containers"][0]
        container["args"] = ['install -d -m 0700 /home/gitlab-runner/.gitlab-runner\n'
            + "printf '%s\\n' " + self.system_id + ' > /home/gitlab-runner/.gitlab-runner/.runner_system_id\n'
            +
            'sed -e "s|__RUNNER_INT_TOKEN__|${RUNNER_INT_TOKEN}|g" -e "s|__RUNNER_RELEASE_TOKEN__|${RUNNER_RELEASE_TOKEN}|g" '
            '/config/config.template.toml > /home/gitlab-runner/.gitlab-runner/config.toml\n'
            'exec gitlab-runner run --config=/home/gitlab-runner/.gitlab-runner/config.toml --user=gitlab-runner --working-directory=/home/gitlab-runner']
        container["env"] = [{"name": "RUNNER_" + lane.upper() + "_TOKEN", "valueFrom": {"secretKeyRef": {
            "name": self.name, "key": lane + "-token"}}} for lane in TAGS]
        pod["spec"]["volumes"][0]["configMap"]["name"] = self.name
        return [resource("ConfigMap", self.name, NAMESPACE, data={"config.template.toml": config}), deployment]

    def reconcile(self):
        self.project_settings()
        secret = self.get("secret", self.name)
        self.require_owned(secret)
        saved = {key: base64.b64decode(value).decode() for key, value in (secret or {}).get("data", {}).items()}
        # Install the complete boundary before registering any eligible runner.
        for document in self.permissions():
            existing = self.get(document["kind"], document["metadata"]["name"], document["metadata"].get("namespace"))
            self.require_owned(existing)
            self.apply(document)
        self.prepare_applications()
        runner_ids = []
        for lane, tag in TAGS.items():
            description = self.name + "-" + lane
            runners = self.api.call("GET", f"projects/{self.project}/runners?type=project_type&per_page=100")
            matches = [item for item in runners if item.get("description") == description]
            if len(matches) > 1 or len(runners) >= 100:
                raise ServiceError("Ambiguous project runner inventory; reconcile duplicate registrations explicitly")
            desired = {"description": description, "tag_list": [tag], "locked": True, "run_untagged": False,
                       "access_level": "ref_protected" if lane == "release" else "not_protected", "paused": False}
            if matches:
                identity = matches[0]["id"]
                current = self.api.call("GET", f"runners/{identity}")
                if current.get("runner_type") != "project_type" or [item["id"] for item in current.get("projects", [])] != [int(self.project)]:
                    raise ServiceError("A delivery runner is assigned to another project")
                token = saved.get(lane + "-token") if saved.get(lane + "-id") == str(identity) else None
                if token:
                    try:
                        verified = HTTP(self.api.url, self.api.headers).request("POST", "/runners/verify", {
                            "token": token, "system_id": self.system_id})
                        if verified.get("id") != identity:
                            token = None
                    except HTTPFailure as error:
                        if error.status not in (401, 403):
                            raise
                        token = None
                if not token:
                    self.require_idle()
                    token = self.api.call("POST", f"runners/{identity}/reset_authentication_token")["token"]
                self.api.call("PUT", f"runners/{identity}", desired)
            else:
                result = self.api.call("POST", "user/runners", {**desired, "runner_type": "project_type", "project_id": int(self.project)})
                identity, token = result["id"], result["token"]
            if not re.fullmatch(r"[A-Za-z0-9_.-]+", token):
                raise ServiceError("GitLab returned an unsupported runner token format")
            runner_ids.append(identity)
            saved.update({lane + "-id": str(identity), lane + "-token": token})
            # Persist immediately, so interruption after creating the other lane
            # never leaves a usable credential only in process memory.
            self.apply(resource("Secret", self.name, NAMESPACE, type="Opaque",
                data={key: base64.b64encode(value.encode()).decode() for key, value in saved.items()}))
        for document in self.runner_resources():
            existing = self.get(document["kind"], self.name)
            self.require_owned(existing)
            if document["kind"] == "Deployment":
                template = document["spec"]["template"]
                annotations = template["metadata"]["annotations"]
                annotations["bm-cluster.io/runner-credentials"] = hashlib.sha256(json.dumps(saved, sort_keys=True).encode()).hexdigest()
                template_hash = hashlib.sha256(json.dumps(template, sort_keys=True).encode()).hexdigest()
                if existing and existing["spec"]["template"]["metadata"].get("annotations", {}).get("bm-cluster.io/runner-template") != template_hash:
                    self.require_idle()
                annotations["bm-cluster.io/runner-template"] = template_hash
            self.apply(document)
        self.kubectl("rollout", "status", "deployment/" + self.name, "-n", NAMESPACE, "--timeout=120s")
        self.api.call("PUT", "projects/" + self.project, {"shared_runners_enabled": False,
            "group_runners_enabled": False, "ci_separated_caches": True,
            "ci_config_path": ".gitlab-ci.yml", "ci_push_repository_for_job_token_allowed": True})
        # Unassign legacy project runners from this project, without deleting
        # their registration or affecting any other application's runner.
        runners = self.api.call("GET", f"projects/{self.project}/runners?type=project_type&per_page=100")
        for runner in runners:
            if runner["id"] not in runner_ids:
                self.api.call("DELETE", f"projects/{self.project}/runners/{runner['id']}")
        project = self.api.call("GET", "projects/" + self.project)
        if project.get("shared_runners_enabled") is not False or project.get("group_runners_enabled") is not False:
            raise ServiceError("GitLab did not isolate this project's delivery runners")

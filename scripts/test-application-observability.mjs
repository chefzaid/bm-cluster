import assert from 'node:assert/strict';
import { test } from 'node:test';
import { mkdtemp, readFile, readdir, rm, stat } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { pathToFileURL } from 'node:url';
import http from 'node:http';

const { discover, grafanaDashboard, kibanaObjects, Api, workloadPaths, reconcile } =
  await import(pathToFileURL(process.env.APPLICATION_OBSERVABILITY_MODULE));

function workload(kind, name, { app, namespace = 'apps', labels = {}, parent, annotations = {} } = {}) {
  return { kind, metadata: {
    name, namespace, uid: `${namespace}-${kind}-${name}`, labels,
    annotations: app ? { 'argocd.argoproj.io/tracking-id': `${app}:group/${kind}:${namespace}/${name}`, ...annotations } : annotations,
    ownerReferences: parent ? [{ controller: true, kind: parent.kind, name: parent.metadata.name, uid: parent.metadata.uid }] : [],
  } };
}

test('groups apps components and their owned pods, excluding every other namespace', () => {
  const deployment = workload('Deployment', 'backend', { app: 'shop' });
  const replica = workload('ReplicaSet', 'backend-abc123', { parent: deployment });
  const pod = workload('Pod', 'backend-abc123-xyz12', { parent: replica });
  const cron = workload('CronJob', 'database-backup', { app: 'shop' });
  const job = workload('Job', 'database-backup-1234', { parent: cron });
  const results = discover([deployment, replica, pod, cron, job,
    workload('Deployment', 'frontend', { app: 'shop' }), workload('Deployment', 'unrelated', { app: 'other' }),
    workload('Deployment', 'vendor', { app: 'vendor', namespace: 'corp' }), workload('Pod', 'infra-tool', { namespace: 'infra' })]);
  assert.equal(results.length, 2);
  const shop = results.find(app => app.name === 'shop');
  assert.deepEqual(shop.workloads, ['CronJob/database-backup', 'Deployment/backend', 'Deployment/frontend']);
  const regex = new RegExp(`^(${shop.patterns.join('|')})$`);
  for (const name of ['backend-abc123-xyz12', 'backend-def456-new12', 'frontend-abc123-xyz12', 'database-backup-12345-xyz12']) assert.match(name, regex);
  for (const name of ['unrelated-abc123-xyz12', 'backend-extra-abc123-xyz12', 'backend-abc123-xyz12-extra']) assert.doesNotMatch(name, regex);
});

test('uses pod-template labels and supports unlabeled and scaled-to-zero workloads', () => {
  const labeled = workload('Deployment', 'api');
  labeled.spec = { template: { metadata: { labels: { 'app.kubernetes.io/part-of': 'billing' } } } };
  const results = discover([labeled, workload('Deployment', 'worker', { labels: { 'app.kubernetes.io/part-of': 'billing' } }),
    workload('StatefulSet', 'database'), workload('DaemonSet', 'collector'), workload('Job', 'migration'), workload('Pod', 'standalone')]);
  assert.equal(results.length, 5);
  assert.equal(results.find(app => app.name === 'billing').workloads.length, 2);
  assert.deepEqual(results.find(app => app.name === 'StatefulSet/database').patterns, ['database-[0-9]+']);
  assert.deepEqual(results.find(app => app.name === 'Pod/standalone').patterns, ['standalone']);
});

test('stable IDs and filters survive ordering, pod churn and changing replica counts', () => {
  const deployment = workload('Deployment', 'api', { app: 'shop' });
  const replica = workload('ReplicaSet', 'api-abc123', { parent: deployment });
  const first = discover([deployment, replica, workload('Pod', 'api-abc123-first', { parent: replica })]);
  assert.deepEqual(first, discover([workload('Pod', 'api-abc123-second', { parent: replica }), replica, deployment]));
  assert.deepEqual(first, discover([deployment]));
});

test('ignores stale owner UIDs and copied tracking annotations', () => {
  const deployment = workload('Deployment', 'api', { app: 'shop' });
  const replica = workload('ReplicaSet', 'api-old', { parent: deployment });
  replica.metadata.ownerReferences[0].uid = 'deleted-deployment';
  replica.metadata.labels = { app: 'orphan' };
  const results = discover([deployment, replica, workload('Pod', 'loose', { annotations: deployment.metadata.annotations })]);
  assert.deepEqual(results.find(app => app.name === 'shop').workloads, ['Deployment/api']);
  assert.ok(results.find(app => app.name === 'orphan'));
  assert.ok(results.find(app => app.name === 'Pod/loose'));
});

test('escapes regex characters and keeps distinct identities with the same name separate', () => {
  const results = discover([workload('Pod', 'release.v1'), workload('Deployment', 'argo', { app: 'shop' }),
    workload('Deployment', 'helm', { labels: { app: 'shop' } })]);
  const standalone = results.find(app => app.name === 'Pod/release.v1');
  assert.match('release.v1', new RegExp(`^${standalone.patterns[0]}$`));
  assert.doesNotMatch('release-v1', new RegExp(`^${standalone.patterns[0]}$`));
  assert.equal(new Set(results.map(app => app.uid)).size, 3);
});

test('groups unlabeled custom-controller pods by their owner', () => {
  const controller = workload('CustomWorker', 'custom');
  const apps = discover([workload('Pod', 'custom-first', { parent: controller }), workload('Pod', 'custom-second', { parent: controller })]);
  assert.equal(apps.length, 1);
  assert.equal(apps[0].name, 'CustomWorker/custom');
  assert.deepEqual(apps[0].patterns, ['custom-first', 'custom-second']);
});

test('every metric query and log panel is scoped to the app, with valid saved-object references', () => {
  const application = discover([workload('Deployment', 'shop-api', { app: 'shop' })])[0];
  const dashboard = grafanaDashboard(application, 'https://kibana.example.com');
  assert.equal(dashboard.panels.length, 12);
  for (const panel of dashboard.panels) for (const target of panel.targets) {
    assert.ok(target.expr.includes('namespace="apps"'));
    assert.ok(target.expr.includes('pod=~"shop-api-[a-z0-9]+-[a-z0-9]+"'));
    assert.ok(!target.expr.includes('kube_pod_labels'));
  }
  const objects = kibanaObjects(application);
  const ids = new Set(objects.map(object => `${object.type}/${object.id}`));
  for (const object of objects) {
    for (const reference of object.references) assert.ok(ids.has(`${reference.type}/${reference.id}`));
    if (object.type === 'index-pattern') continue;
    const source = JSON.parse(object.attributes.kibanaSavedObjectMeta.searchSourceJSON);
    assert.deepEqual(source.filter[0].query.bool.filter[0], { term: { 'kubernetes.namespace_name': 'apps' } });
    assert.equal(source.filter[0].query.bool.filter[1].regexp['kubernetes.pod_name'].value, application.patterns.join('|'));
  }
  assert.ok(dashboard.links[0].url.endsWith(objects.at(-1).id));
});

async function fixture(run) {
  const directory = await mkdtemp(join(tmpdir(), 'application-observability-'));
  const state = { workloads: [workload('Deployment', 'api', { app: 'shop' })], imports: [], imported: new Map() };
  const kubernetes = { async list(path) { assert.ok(workloadPaths.includes(path)); return path.endsWith('/deployments') ? state.workloads : []; } };
  const kibana = { async importObjects(objects) { state.imports.push(objects); } };
  const args = { kubernetes, kibana, directory, kibanaUrl: 'https://kibana.example.com', imported: state.imported, now: 1000 };
  try { await run(args, state); } finally { await rm(directory, { recursive: true, force: true }); }
}

test('idempotent reconciliation repairs Kibana periodically and retains removed dashboards', async () => {
  await fixture(async (args, state) => {
    const first = await reconcile(args);
    const path = join(args.directory, `${first.applications[0].uid}.json`);
    const modified = (await stat(path)).mtimeMs;
    await reconcile({ ...args, now: 2000 });
    assert.equal(state.imports.length, 1);
    assert.equal((await stat(path)).mtimeMs, modified);
    assert.deepEqual(await readdir(args.directory), [`${first.applications[0].uid}.json`]);
    await reconcile({ ...args, now: 302000 });
    assert.equal(state.imports.length, 2);
    state.workloads = [];
    assert.equal((await reconcile(args)).applications.length, 0);
    assert.equal(JSON.parse(await readFile(path, 'utf8')).uid, first.applications[0].uid);
  });
});

test('discovers new applications and components without a maintained app inventory', async () => {
  await fixture(async (args, state) => {
    const first = await reconcile(args);
    state.workloads.push(workload('Deployment', 'worker', { app: 'shop' }), workload('Deployment', 'future-service', { app: 'future' }));
    const next = await reconcile(args);
    assert.equal(next.applications.length, 2);
    assert.equal(next.applications.find(app => app.name === 'shop').uid, first.applications[0].uid);
    assert.equal(state.imports.length, 3);
    assert.equal((await readdir(args.directory)).length, 2);
  });
});

test('Kibana failure does not block Grafana or other apps and retries failed imports', async () => {
  await fixture(async (args, state) => {
    state.workloads.push(workload('Deployment', 'other', { app: 'other' }));
    const original = args.kibana.importObjects;
    args.kibana.importObjects = async objects => {
      if (objects.at(-1).attributes.title.includes('/ shop /')) throw new Error('HTTP 503');
      return original(objects);
    };
    assert.equal((await reconcile(args)).errors.length, 1);
    assert.equal((await readdir(args.directory)).length, 2);
    assert.equal(state.imported.size, 1);
    args.kibana.importObjects = original;
    assert.deepEqual((await reconcile(args)).errors, []);
    assert.equal(state.imported.size, 2);
  });
});

test('partial Kubernetes snapshots cannot overwrite known dashboards', async () => {
  await fixture(async (args, state) => {
    await reconcile(args);
    args.kubernetes.list = async () => { throw new Error('HTTP 403'); };
    await assert.rejects(reconcile(args), /403/);
    assert.equal((await readdir(args.directory)).length, 1);
    assert.equal(state.imports.length, 1);
  });
});

test('API pagination follows continuation tokens and never includes secret response bodies in errors', async () => {
  const requests = [];
  const server = http.createServer((request, response) => {
    requests.push(request.url);
    response.setHeader('Content-Type', 'application/json');
    if (request.url.startsWith('/failure')) { response.writeHead(403); response.end('{"token":"private-test-credential"}'); }
    else if (request.url.includes('continue=next')) response.end('{"kind":"PodList","items":[{"name":"second"}],"metadata":{}}');
    else response.end('{"kind":"PodList","items":[{"name":"first"}],"metadata":{"continue":"next"}}');
  });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  try {
    const api = new Api(`http://127.0.0.1:${server.address().port}`);
    assert.deepEqual(await api.list('/pods'), [{ name: 'first', kind: 'Pod' }, { name: 'second', kind: 'Pod' }]);
    assert.equal(requests.length, 2);
    await assert.rejects(api.call('GET', '/failure'), error => /HTTP 403/.test(error.message) && !error.message.includes('private-test-credential'));
    await assert.rejects(api.call('GET', 'http://example.invalid/leak'), /Cross-origin/);
  } finally { await new Promise(resolve => server.close(resolve)); }
});

test('partial saved-object imports fail even when HTTP succeeds', async () => {
  const api = new Api('http://kibana.invalid');
  api.call = async (_method, _path, payload, contentType) => {
    assert.ok(contentType.startsWith('multipart/form-data; boundary='));
    assert.ok(payload.includes('filename="applications.ndjson"'));
    return { success: false, successCount: 1 };
  };
  await assert.rejects(api.importObjects([{ type: 'dashboard', id: 'fixture' }]), /incomplete/);
});

# Langflow runtime chart

Deploy Langflow flows to Kubernetes with this Helm chart.
Using a dedicated deployment for a set of flows is fundamental in production environments in order to have a granular resource control.

## PostgreSQL and PreSync initialization

For multi-replica runtime deployments, this chart can initialize Langflow against the target database before the main Deployment starts.

Use a pinned Langflow image tag instead of `latest`. On May 18, 2026, the latest stable GitHub release listed by Langflow is `1.9.2`, while `latest` can move independently and may pull a newer Python runtime.

The chart now supports:

```yaml
image:
  tag: "1.9.2"

database:
  url: "postgresql://langflow:langflow@langflow-postgres:5432/langflow"

presyncJob:
  enabled: true
  runOnce: true
  healthCheck:
    url: "http://127.0.0.1:7860/health_check"
    maxRetry: 60
    sleepSec: 3
    requireChatOk: false
```

When `presyncJob.enabled=true`, the chart renders an Argo CD `PreSync` Job that:

1. Uses the same runtime image and env configuration as the Deployment
2. Starts Langflow once in the background
3. Polls `http://127.0.0.1:7860/health_check` with Python `urllib.request`
4. Exits `0` on DB-ready success, or `1` on timeout/failure

The database URL is injected through a generated Secret and exposed to both the Job and Deployment through `LANGFLOW_DATABASE_URL`.

The health-check script tolerates optional `status`, `chat`, and `db` fields in the `/health_check` response, which matches the Langflow API schema.

Example manifests and values for the `langflow-test` namespace are available here:

- `examples/langflow-runtime/langflow-test-postgres.yaml`
- `examples/langflow-runtime/langflow-test-values-postgres.yaml`

Apply the test PostgreSQL setup:

```bash
kubectl apply -f examples/langflow-runtime/langflow-test-postgres.yaml
kubectl get namespace langflow-test
kubectl get svc langflow-postgres -n langflow-test
```

Test PostgreSQL connectivity:

```bash
kubectl run pg-test \
  -n langflow-test \
  --image=postgres:16 \
  --restart=Never \
  --rm -it \
  --env="PGPASSWORD=langflow" \
  --command -- psql -h langflow-postgres -U langflow -d langflow -c "select 1;"
```

If the PVC already contains data, PostgreSQL image initialization does not recreate the configured DB/user automatically. In that case:

```bash
kubectl exec -it deploy/langflow-postgres -n langflow-test -- \
  psql -U langflow -d postgres -c "CREATE DATABASE langflow_runtime;"

kubectl exec -it deploy/langflow-postgres -n langflow-test -- \
  psql -U langflow -d postgres -c "GRANT ALL PRIVILEGES ON DATABASE langflow_runtime TO langflow;"

kubectl exec -it deploy/langflow-postgres -n langflow-test -- \
  psql -U langflow -d langflow -c "CREATE SCHEMA IF NOT EXISTS langflow AUTHORIZATION langflow;"
```

If you need a completely clean state for another test run:

```bash
kubectl delete deploy langflow-postgres -n langflow-test
kubectl delete pvc langflow-postgres-pvc -n langflow-test
```

Validate rendered manifests locally:

```bash
helm template langflow-runtime ./charts/langflow-runtime \
  -n langflow-test \
  -f ./examples/langflow-runtime/langflow-test-values-postgres.yaml
```

Install or upgrade for chart validation:

```bash
helm upgrade --install langflow-runtime ./charts/langflow-runtime \
  -n langflow-test \
  -f ./examples/langflow-runtime/langflow-test-values-postgres.yaml
```

Inspect the result:

```bash
kubectl get secret,job,deploy,svc,pod -n langflow-test
kubectl logs job/langflow-runtime-db-init -n langflow-test
kubectl get pods -n langflow-test
```

`helm upgrade --install` is useful for chart validation, but Argo CD Sync is still required to validate real `PreSync` hook ordering.

## Import a flow

There are two ways to import a flow:

1. **From a remote location**: You can reference a flow stored in a remote location, such as a URL or a Git repository by customizing the `values.yaml` file in the section `downloadFlows`:

```yaml
downloadFlows:
  flows:
    - url: https://raw.githubusercontent.com/datastax/langflow-charts/main/examples/flows/basic-prompting-hello-world.json
      endpoint: hello-world
```

2. **Packaging the flow as docker image**: You can add a flow from to a docker image based on Langflow runtime and refer to it in the chart.
   See an example in the `apps` directory.

## Deploy the flow

Since the basic prompting needs an OpenAI Key, we need to create a secret with the key:
```
kubectl create secret generic langflow-secrets --from-literal=openai-key=sk-xxxx
```
This command will create a secret named `langflow-secrets` with the key `openai-key` containing your secret value.

We need to create a custom `values.yaml` file to:
1. Refer to the flow we want to deploy
2. Plug the secret we created to the Langflow deployment

(custom-values.yaml)
```yaml
downloadFlows:
  flows:
  - url: https://raw.githubusercontent.com/datastax/langflow-charts/main/examples/flows/basic-prompting-hello-world.json
    endpoint: hello-world

env:
  - name: LANGFLOW_LOG_LEVEL
    value: "INFO"
  - name: OPENAI_API_KEY
    valueFrom:
      secretKeyRef:
        name: langflow-secrets
        key: openai-key
```
See the full file at [basic-prompting-hello-world.yaml](https://raw.githubusercontent.com/datastax/langflow-charts/main/examples/flows/langflow-runtime/basic-prompting-hello-world.yaml)

Now we can deploy the chart (using option 1):

```bash
helm repo add langflow https://langflow-ai.github.io/langflow-helm-charts
helm repo update
helm install langflow-runtime langflow/langflow-runtime --values custom-values.yaml
```

Tunnel the service to localhost:

```bash
kubectl port-forward svc/langflow-langflow-runtime 7860:7860
```

Call the flow API endpoint using `hello-world` as flow name:
```bash
curl -X POST \
    "http://localhost:7860/api/v1/run/hello-world?stream=false" \
    -H 'Content-Type: application/json'\
    -d '{
      "input_value": "Hello there!",
      "output_type": "chat",
      "input_type": "chat"
    }'
```


## Upgrade Langflow version
To change the Langflow version or use a custom docker image, you can modify the `image` parameter in the chart.

```yaml
image:
  repository: "langflowai/langflow-backend"
  tag: 1.x.y
```

## Download flows options
The `downloadFlows` section in the `values.yaml` file allows you to download flows from remote locations.
You can specify the following options:
* `url`: The URL of the flow. Must point to a JSON file.
* `endpoint`: Override the endpoint of the flow. By default, the endpoint is the UUID of the flow or anything you set in the flow (`endpoint_name` key).
* `uuid`: Override the UUID of the flow. If not specified, the UUID will be extracted from the flow file.
* `basicAuth`: Basic authentication credentials in the form `username:password`.
* `headers`: Custom headers to add to the request. For example, to add Authorization header for downloading from private repositories.

## Langflow secrets
The `env` section in the `values.yaml` file allows you to set environment variables for the Langflow deployment.
The recommended way to set sensitive information is to use Kubernetes secrets.
You can reference a secret in the `values.yaml` file by using the `valueFrom` key.

```yaml
env:
  - name: OPENAI_API_KEY
    valueFrom:
      secretKeyRef:
        name: langflow-secrets
        key: openai-key
  - name: ASTRA_DB_APPLICATION_TOKEN
    valueFrom:
      secretKeyRef:
        name: langflow-secrets
        key: astra-token
```
where:
* `name`: refer to the environment variable name used by your flow.
* `valueFrom.secretKeyRef.name`: refers to the kubernetes secret name.
* `valueFrom.secretKeyRef.key`: refers to the key in the secret.
For example, to create a matching secret with the above example you can use the following command:

```
kubectl create secret generic langflow-secrets --from-literal=openai-key=sk-xxxx --from-literal=astra-token=AstraCS:xxx
```


## Scale the flows

In order to add more resources to the flows container, you could decide to scale:
- Horizontally, by adding more replicas of the deployment
- Vertically, by adding more cpu/memory resources to the deployment


### Scale horizontally

To scale horizontally you only need to modify the `replicaCount` parameter in the chart.

```
replicaCount: 5
```

Please note that if your flow relies on shared state (e.g. builtin chat memory), you will need to setup a shared database.

### Scale vertically

By default the deployment doesn't have any limits and it could consume all the node resources. 
In order to limit the available resources, you can modify the `resources` value:

```yaml
resources:
  limits:
    cpu: 100m
    memory: 128Mi
  requests:
    cpu: 100m
    memory: 128Mi
```

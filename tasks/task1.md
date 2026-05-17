# SDD: langflow-test Namespace PostgreSQL 구성 및 Langflow Runtime Helm PreSync Job 추가

## 1. 목적

이 문서는 기존에 구성된 k3s 환경과 현재 보유 중인 Langflow Helm chart workspace를 기준으로, Langflow Runtime 외부 PostgreSQL 연동 및 PreSync Job 기반 초기화 검증 구조를 구현하기 위한 SDD 문서다.

주요 목표는 다음과 같다.

1. `langflow-test` namespace에 PostgreSQL을 구성한다.
2. 기존 Langflow Helm chart workspace의 Runtime Helm template에 PreSync Job을 추가한다.
3. PreSync Job은 Runtime Deployment manifest와 최대한 동일한 실행 조건을 사용한다.
4. Runtime과 PreSync Job 모두 1번에서 생성한 PostgreSQL과 연동되도록 `values.yaml`을 구성한다.
5. 필요 시 PostgreSQL database/user/schema 생성 작업도 배포 순서에 포함한다.
6. Runtime replicas >= 2 환경에서 DB 초기화 경쟁 상태가 완화되는지 검증한다.

---

## 2. 현재 전제

다음 환경이 이미 준비되어 있다고 가정한다.

```text
k3s cluster
  ├─ kubectl 접근 가능
  ├─ helm 사용 가능
  ├─ Argo CD 사용 가능 또는 사용 예정
  └─ Langflow Helm chart workspace 존재
```

현재 수정 대상은 새 chart를 만드는 것이 아니라, **이미 존재하는 Langflow Helm chart workspace의 Runtime chart/template**이다.

---

## 3. 문제 정의

Langflow Runtime은 외부 PostgreSQL을 사용하도록 구성할 수 있다.

그러나 최초 배포 시 Runtime replicas가 2 이상이면 여러 Runtime Pod가 동시에 기동되면서 DB 초기화 작업을 동시에 수행할 수 있다.

예상 가능한 문제는 다음과 같다.

| 문제                   | 설명                                            |
| -------------------- | --------------------------------------------- |
| DB schema 초기화 충돌     | 여러 Pod가 같은 table/index/constraint 생성을 동시에 시도  |
| 기본 데이터 중복 생성         | folder, user, flow metadata 등이 중복 insert될 가능성 |
| FK 오류                | 참조 데이터 생성 전 다른 데이터가 먼저 insert될 가능성            |
| unique constraint 오류 | 동일 key/name/id를 여러 Pod가 동시에 insert            |
| Runtime 일부 실패        | 한 Pod는 성공하고 다른 Pod는 CrashLoop 가능              |

해결 가설은 다음과 같다.

> 실제 Runtime Deployment가 replicas >= 2로 실행되기 전에, Argo CD PreSync Job에서 Runtime과 동일한 image/env 설정으로 Langflow를 1회 기동하고 `/health_check`가 성공하면 종료한다. 이후 실제 Runtime Deployment가 실행되도록 한다.

---

## 4. 전체 작업 순서

권장 작업 순서는 다음과 같다.

```text
1. langflow-test namespace 생성
2. PostgreSQL 구성
3. PostgreSQL database/user/schema 확인 또는 추가 생성
4. Langflow Runtime DB URL 결정
5. Helm values에 DB 연동 값 추가
6. Runtime Deployment manifest의 DB env 확인
7. Runtime Deployment와 동일 조건을 쓰는 PreSync Job template 추가
8. Helm template 렌더링 검증
9. Helm install 또는 Argo CD Sync 전 dry-run 검증
10. Argo CD Sync로 PreSync Job 실행 순서 검증
11. Runtime replicas >= 2 기동 검증
12. 로그에서 DB 초기화 충돌 여부 확인
```

---

## 5. Namespace 구성

## 5.1 namespace 생성 명령

```sh
kubectl create namespace langflow-test --dry-run=client -o yaml | kubectl apply -f -
```

확인:

```sh
kubectl get namespace langflow-test
```

---

## 6. PostgreSQL 구성

## 6.1 목적

`langflow-test` namespace 안에 테스트용 PostgreSQL을 구성한다.

이 PostgreSQL은 Langflow Runtime에서 사용할 외부 DB 역할을 한다.

운영용 고가용성 DB가 아니라, Runtime 외부 DB 연동 및 초기화 충돌 검증을 위한 단순 구성이다.

## 6.2 PostgreSQL Secret 생성

```sh
kubectl create secret generic langflow-postgres-secret \
  -n langflow-test \
  --from-literal=POSTGRES_DB=langflow \
  --from-literal=POSTGRES_USER=langflow \
  --from-literal=POSTGRES_PASSWORD=langflow \
  --dry-run=client -o yaml | kubectl apply -f -
```

확인:

```sh
kubectl get secret langflow-postgres-secret -n langflow-test
```

## 6.3 PostgreSQL PVC 생성

```sh
cat <<'EOF' | kubectl apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: langflow-postgres-pvc
  namespace: langflow-test
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 2Gi
EOF
```

확인:

```sh
kubectl get pvc -n langflow-test
kubectl get storageclass
```

주의:

* k3s 기본 local-path-provisioner가 활성화되어 있으면 PVC가 자동 바인딩될 가능성이 높다.
* PVC가 Pending이면 StorageClass 설정을 확인해야 한다.

## 6.4 PostgreSQL Deployment 생성

```sh
cat <<'EOF' | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: langflow-postgres
  namespace: langflow-test
spec:
  replicas: 1
  selector:
    matchLabels:
      app: langflow-postgres
  template:
    metadata:
      labels:
        app: langflow-postgres
    spec:
      containers:
        - name: postgres
          image: postgres:16
          imagePullPolicy: IfNotPresent
          ports:
            - name: postgres
              containerPort: 5432
          envFrom:
            - secretRef:
                name: langflow-postgres-secret
          volumeMounts:
            - name: data
              mountPath: /var/lib/postgresql/data
          readinessProbe:
            exec:
              command:
                - sh
                - -c
                - pg_isready -U "$POSTGRES_USER" -d "$POSTGRES_DB"
            initialDelaySeconds: 5
            periodSeconds: 5
            failureThreshold: 12
      volumes:
        - name: data
          persistentVolumeClaim:
            claimName: langflow-postgres-pvc
EOF
```

확인:

```sh
kubectl rollout status deployment/langflow-postgres -n langflow-test --timeout=180s
kubectl get pods -n langflow-test -l app=langflow-postgres
```

## 6.5 PostgreSQL Service 생성

```sh
cat <<'EOF' | kubectl apply -f -
apiVersion: v1
kind: Service
metadata:
  name: langflow-postgres
  namespace: langflow-test
spec:
  type: ClusterIP
  selector:
    app: langflow-postgres
  ports:
    - name: postgres
      port: 5432
      targetPort: postgres
EOF
```

확인:

```sh
kubectl get svc langflow-postgres -n langflow-test
```

## 6.6 PostgreSQL 접속 테스트

```sh
kubectl run pg-test \
  -n langflow-test \
  --image=postgres:16 \
  --restart=Never \
  --rm -it \
  --env="PGPASSWORD=langflow" \
  --command -- psql -h langflow-postgres -U langflow -d langflow -c "select 1;"
```

성공 기준:

```text
?column?
----------
        1
```

## 6.7 필요한 경우 database/user/schema 추가 작업

기본 Secret에서 `POSTGRES_DB=langflow`, `POSTGRES_USER=langflow`를 지정하면 PostgreSQL 최초 초기화 시 해당 DB와 사용자가 생성된다.

다만 다음 경우에는 추가 SQL 작업이 필요할 수 있다.

| 상황                           | 필요한 작업                      |
| ---------------------------- | --------------------------- |
| PVC가 이미 존재해서 초기화가 다시 수행되지 않음 | 직접 DB/user 생성 필요            |
| 다른 DB 이름을 사용하고 싶음            | `CREATE DATABASE` 수행        |
| 다른 계정을 사용하고 싶음               | `CREATE USER`, `GRANT` 수행   |
| schema를 분리하고 싶음              | `CREATE SCHEMA`, `GRANT` 수행 |

추가 SQL 예시:

```sh
kubectl exec -it deploy/langflow-postgres -n langflow-test -- \
  psql -U langflow -d langflow -c "select current_database(), current_user;"
```

DB 생성 예시:

```sh
kubectl exec -it deploy/langflow-postgres -n langflow-test -- \
  psql -U langflow -d postgres -c "CREATE DATABASE langflow_runtime;"
```

권한 부여 예시:

```sh
kubectl exec -it deploy/langflow-postgres -n langflow-test -- \
  psql -U langflow -d postgres -c "GRANT ALL PRIVILEGES ON DATABASE langflow_runtime TO langflow;"
```

주의:

* PostgreSQL 공식 image는 데이터 디렉터리가 비어 있을 때만 `POSTGRES_DB`, `POSTGRES_USER`, `POSTGRES_PASSWORD` 초기화를 수행한다.
* PVC를 재사용하면 Secret 값을 바꿔도 DB가 자동으로 다시 생성되지 않는다.
* 완전 초기 상태로 테스트하려면 PVC를 삭제해야 한다.

PVC 삭제:

```sh
kubectl delete pvc langflow-postgres-pvc -n langflow-test
```

---

## 7. Langflow Runtime DB URL

Runtime과 PreSync Job에서 사용할 DB URL은 다음을 기준으로 한다.

```text
postgresql://langflow:langflow@langflow-postgres:5432/langflow
```

같은 namespace인 `langflow-test`에 Runtime과 PostgreSQL이 함께 배포되므로 Service short name을 사용할 수 있다.

전체 FQDN을 쓰려면 다음과 같다.

```text
postgresql://langflow:langflow@langflow-postgres.langflow-test.svc.cluster.local:5432/langflow
```

---

## 8. Helm values 설정

기존 Langflow Helm chart workspace의 Runtime values에 다음 구조를 추가하거나 기존 구조에 맞게 매핑한다.

예시:

```yaml
runtime:
  replicaCount: 2

  image:
    repository: langflowai/langflow
    tag: "1.9.0"
    pullPolicy: IfNotPresent

  service:
    port: 7860

  database:
    external: true
    url: "postgresql://langflow:langflow@langflow-postgres:5432/langflow"

  langflow:
    port: 7860
    command: "langflow run --backend-only --host 0.0.0.0 --port 7860"

  presyncJob:
    enabled: true
    runOnce: true
    healthCheck:
      url: "http://127.0.0.1:7860/health_check"
      maxRetry: 60
      sleepSec: 3
      requireChatOk: false
```

만약 기존 chart가 flat 구조라면 다음처럼 구성할 수 있다.

```yaml
replicaCount: 2

image:
  repository: langflowai/langflow
  tag: "1.9.0"
  pullPolicy: IfNotPresent

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

주의:

* 실제 values path는 현재 workspace의 Runtime chart 구조에 맞춰야 한다.
* 기존 Runtime Deployment가 사용하는 image/env/command 값을 재사용하는 방식이 가장 안전하다.

---

## 9. Runtime Deployment manifest 수정 기준

기존 Runtime Deployment manifest에 외부 DB URL이 주입되어야 한다.

권장 방식은 Secret을 사용하는 것이다.

## 9.1 DB Secret template 추가

예시 파일:

```text
charts/<langflow-chart>/templates/runtime-db-secret.yaml
```

예시 manifest:

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: {{ include "langflow.fullname" . }}-runtime-db
type: Opaque
stringData:
  database-url: {{ .Values.runtime.database.url | quote }}
```

flat values 구조라면:

```yaml
stringData:
  database-url: {{ .Values.database.url | quote }}
```

## 9.2 Runtime Deployment env 추가

Runtime Deployment container에 다음 env를 추가한다.

```yaml
- name: LANGFLOW_DATABASE_URL
  valueFrom:
    secretKeyRef:
      name: {{ include "langflow.fullname" . }}-runtime-db
      key: database-url
```

주의:

* 현재 chart에서 사용하는 실제 env 이름이 `LANGFLOW_DATABASE_URL`인지 반드시 확인해야 한다.
* 기존 chart가 이미 DB 관련 env를 가지고 있다면 중복 선언하지 않는다.
* Runtime Deployment와 PreSync Job은 동일한 DB env를 사용해야 한다.

---

## 10. PreSync Job 설계

## 10.1 설계 원칙

PreSync Job은 Runtime Deployment manifest와 최대한 동일하게 구성한다.

동일하게 맞춰야 할 항목:

| 항목                   | 이유                                  |
| -------------------- | ----------------------------------- |
| image repository/tag | 실제 Runtime과 같은 Langflow 버전으로 초기화 검증 |
| imagePullPolicy      | 배포 정책 일관성 유지                        |
| DB env               | 동일 PostgreSQL에 연결                   |
| cache env            | `/health_check`의 chat/cache 검사 일관성  |
| secret/config env    | Runtime과 같은 실행 조건 유지                |
| command/args         | 실제 Runtime 기동 방식과 동일하게 검증           |
| service port         | `/health_check` polling 대상 포트 일치    |
| resource 설정          | 필요 시 Runtime과 유사한 자원 조건 검증          |

단, 다음은 Job에 불필요할 수 있다.

| 항목                           | 이유                    |
| ---------------------------- | --------------------- |
| readinessProbe/livenessProbe | Job 내부 polling으로 대체   |
| serviceAccount               | 필요 없으면 생략 가능          |
| volumeMounts                 | Runtime 기동에 필요할 때만 포함 |
| sidecar                      | Runtime 필수 구성일 때만 포함  |

## 10.2 PreSync Job 실행 흐름

```text
PreSync Job 시작
  → Runtime과 동일한 image/env 구성
  → Langflow를 background process로 기동
  → Python urllib로 /health_check polling
  → db == ok 확인
  → 필요 시 chat == ok 확인
  → Langflow process 종료
  → exit 0
```

실패 흐름:

```text
/health_check timeout
  → Langflow process 종료
  → exit 1
  → Argo CD Sync 실패
  → Runtime Deployment 적용 중단
```

## 10.3 PreSync Job template 예시

예시 파일:

```text
charts/<langflow-chart>/templates/runtime-presync-db-init-job.yaml
```

예시 manifest:

```yaml
{{- if .Values.runtime.presyncJob.enabled }}
apiVersion: batch/v1
kind: Job
metadata:
  name: {{ include "langflow.fullname" . }}-runtime-db-init
  annotations:
    argocd.argoproj.io/hook: PreSync
    argocd.argoproj.io/sync-wave: "-1"
    {{- if not .Values.runtime.presyncJob.runOnce }}
    argocd.argoproj.io/hook-delete-policy: BeforeHookCreation,HookSucceeded
    {{- end }}
spec:
  backoffLimit: 1
  template:
    spec:
      restartPolicy: Never
      containers:
        - name: runtime-db-init
          image: "{{ .Values.runtime.image.repository }}:{{ .Values.runtime.image.tag }}"
          imagePullPolicy: {{ .Values.runtime.image.pullPolicy | default "IfNotPresent" }}
          env:
            - name: LANGFLOW_DATABASE_URL
              valueFrom:
                secretKeyRef:
                  name: {{ include "langflow.fullname" . }}-runtime-db
                  key: database-url
            - name: HEALTH_CHECK_URL
              value: {{ .Values.runtime.presyncJob.healthCheck.url | quote }}
            - name: HEALTH_CHECK_MAX_RETRY
              value: {{ .Values.runtime.presyncJob.healthCheck.maxRetry | quote }}
            - name: HEALTH_CHECK_SLEEP_SEC
              value: {{ .Values.runtime.presyncJob.healthCheck.sleepSec | quote }}
            - name: REQUIRE_CHAT_OK
              value: {{ .Values.runtime.presyncJob.healthCheck.requireChatOk | quote }}
          command:
            - /bin/sh
            - -c
          args:
            - |
              set -e

              cat > /tmp/check-health.py <<'PY'
              import json
              import os
              import time
              import urllib.request
              import sys

              URL = os.getenv("HEALTH_CHECK_URL", "http://127.0.0.1:7860/health_check")
              MAX_RETRY = int(os.getenv("HEALTH_CHECK_MAX_RETRY", "60"))
              SLEEP_SEC = int(os.getenv("HEALTH_CHECK_SLEEP_SEC", "3"))
              REQUIRE_CHAT_OK = os.getenv("REQUIRE_CHAT_OK", "false").lower() == "true"

              for i in range(MAX_RETRY):
                  try:
                      with urllib.request.urlopen(URL, timeout=5) as res:
                          body = res.read().decode("utf-8")
                          data = json.loads(body)

                          db_ok = data.get("db") == "ok"
                          status_ok = data.get("status") == "ok" or data.get("status") is None
                          chat_ok = data.get("chat") == "ok"

                          if db_ok and status_ok and (chat_ok or not REQUIRE_CHAT_OK):
                              print("Langflow health_check passed:", data)
                              sys.exit(0)

                          print("Langflow not ready:", data)

                  except Exception as e:
                      print(f"Waiting for Langflow... attempt={i + 1}, error={e}")

                  time.sleep(SLEEP_SEC)

              print("Langflow health_check failed")
              sys.exit(1)
              PY

              cleanup() {
                if [ -n "$LANGFLOW_PID" ]; then
                  echo "Stopping Langflow process: $LANGFLOW_PID"
                  kill "$LANGFLOW_PID" 2>/dev/null || true
                  wait "$LANGFLOW_PID" 2>/dev/null || true
                fi
              }

              trap cleanup EXIT

              echo "Starting Langflow Runtime for DB initialization check"
              {{ .Values.runtime.langflow.command }} &
              LANGFLOW_PID=$!

              echo "Langflow Runtime started with PID=$LANGFLOW_PID"
              python /tmp/check-health.py
{{- end }}
```

flat values 구조라면 `.Values.runtime.*`를 현재 chart에 맞게 `.Values.*`로 바꾼다.

## 10.4 Runtime Deployment와 동일 구성 재사용 방법

중복을 줄이려면 helper template을 만드는 것을 권장한다.

예:

```text
templates/_runtime.tpl
```

공통 env helper:

```yaml
{{- define "langflow.runtime.env" -}}
- name: LANGFLOW_DATABASE_URL
  valueFrom:
    secretKeyRef:
      name: {{ include "langflow.fullname" . }}-runtime-db
      key: database-url
{{- end -}}
```

Deployment와 Job에서 동일하게 사용:

```yaml
env:
{{ include "langflow.runtime.env" . | nindent 12 }}
```

이렇게 하면 Runtime Deployment와 PreSync Job의 env 차이를 줄일 수 있다.

---

## 11. Runtime Deployment readiness/liveness 설정

Runtime Deployment에는 다음 probe를 권장한다.

```yaml
readinessProbe:
  httpGet:
    path: /health_check
    port: http
  initialDelaySeconds: 10
  periodSeconds: 10
  failureThreshold: 12

livenessProbe:
  httpGet:
    path: /health
    port: http
  initialDelaySeconds: 30
  periodSeconds: 20
  failureThreshold: 6
```

판단:

| Probe          | Endpoint        | 이유                          |
| -------------- | --------------- | --------------------------- |
| readinessProbe | `/health_check` | DB/cache readiness 확인에 더 적합 |
| livenessProbe  | `/health`       | 프로세스 생존 확인 용도               |

---

## 12. Helm template 검증

Runtime chart workspace에서 다음을 수행한다.

```sh
helm template <release-name> <chart-path> \
  -n langflow-test \
  -f <values-file>
```

예시:

```sh
helm template langflow-runtime ./charts/langflow-runtime \
  -n langflow-test \
  -f ./charts/langflow-runtime/values.yaml
```

확인 항목:

* DB Secret 생성 여부
* PreSync Job 생성 여부
* Runtime Deployment 생성 여부
* Runtime Service 생성 여부
* `LANGFLOW_DATABASE_URL` 중복 선언 여부
* YAML indentation 오류 여부
* `.Values.runtime.*` path 오류 여부

---

## 13. Helm install 기본 검증

Argo CD Sync 전에 chart 자체를 검증하려면 Helm install을 수행한다.

```sh
helm upgrade --install langflow-runtime <chart-path> \
  -n langflow-test \
  -f <values-file>
```

확인:

```sh
kubectl get secret,job,deploy,svc,pod -n langflow-test
kubectl logs job/<job-name> -n langflow-test
kubectl logs deploy/<runtime-deployment-name> -n langflow-test --all-containers=true
```

주의:

* Helm install만으로는 Argo CD PreSync phase 동작을 정확히 검증할 수 없다.
* Helm install에서는 Argo CD hook annotation이 일반 annotation처럼 취급된다.
* PreSync 실행 순서는 반드시 Argo CD Sync로 최종 검증해야 한다.

---

## 14. Argo CD Sync 검증

Argo CD Application으로 Runtime chart를 배포한다.

검증 목적:

* PreSync Job이 Runtime Deployment보다 먼저 실행되는지 확인
* Job 실패 시 Runtime 배포가 중단되는지 확인
* Job 성공 후 Runtime replicas >= 2가 기동되는지 확인

확인 명령:

```sh
kubectl get application -n argocd
kubectl get job,pod,deploy -n langflow-test
kubectl get events -n langflow-test --sort-by=.lastTimestamp
kubectl logs job/<runtime-db-init-job-name> -n langflow-test
```

성공 기준:

```text
PreSync Job 실행
  → Langflow Runtime 1회 기동
  → /health_check 성공
  → Job Completed
  → Runtime Deployment 적용
  → Runtime Pod 2개 이상 Running/Ready
```

---

## 15. 테스트 시나리오

## 15.1 PostgreSQL 구성 테스트

```sh
kubectl get pods -n langflow-test -l app=langflow-postgres
kubectl get svc langflow-postgres -n langflow-test
kubectl run pg-test \
  -n langflow-test \
  --image=postgres:16 \
  --restart=Never \
  --rm -it \
  --env="PGPASSWORD=langflow" \
  --command -- psql -h langflow-postgres -U langflow -d langflow -c "select 1;"
```

성공 기준:

* PostgreSQL Pod Ready
* Service 생성됨
* `select 1` 성공

## 15.2 Runtime Helm template 테스트

```sh
helm template langflow-runtime <chart-path> -n langflow-test -f <values-file>
```

성공 기준:

* template rendering 성공
* PreSync Job manifest 포함
* Runtime Deployment manifest 포함
* DB Secret manifest 포함

## 15.3 PreSync Job 단독 로그 테스트

Argo CD 또는 Helm 배포 후:

```sh
kubectl logs job/<runtime-db-init-job-name> -n langflow-test
```

성공 로그 예시:

```text
Starting Langflow Runtime for DB initialization check
Langflow Runtime started with PID=...
Waiting for Langflow...
Langflow health_check passed: {...}
Stopping Langflow process: ...
```

## 15.4 Runtime replicas >= 2 테스트

```sh
kubectl get pods -n langflow-test
kubectl logs deploy/<runtime-deployment-name> -n langflow-test --all-containers=true
```

성공 기준:

* Runtime Pod 2개 이상 Running/Ready
* DB 관련 duplicate key/FK/table exists 오류 없음
* `/health_check` readiness 성공

## 15.5 PreSync Job 없는 경우 비교 테스트

1. values에서 PreSync Job 비활성화

```yaml
runtime:
  presyncJob:
    enabled: false
```

2. PostgreSQL PVC 삭제 후 빈 DB 재구성

```sh
kubectl delete deploy langflow-postgres -n langflow-test
kubectl delete pvc langflow-postgres-pvc -n langflow-test
```

3. PostgreSQL 재배포
4. Runtime replicas=2 배포
5. 로그 확인

확인할 오류:

* duplicate key
* foreign key violation
* table already exists
* migration conflict
* flow/folder 관련 insert 오류

---

## 16. 추가 작업 고려사항

## 16.1 DB 초기화 상태를 완전히 초기화하고 싶을 때

PostgreSQL PVC를 삭제해야 한다.

```sh
kubectl delete pvc langflow-postgres-pvc -n langflow-test
```

PVC 삭제 후 PostgreSQL Deployment를 다시 생성하면 빈 DB에서 다시 테스트할 수 있다.

## 16.2 DB 이름을 바꾸고 싶을 때

Secret의 `POSTGRES_DB`와 values의 DB URL을 함께 수정해야 한다.

예:

```text
POSTGRES_DB=langflow_runtime
postgresql://langflow:langflow@langflow-postgres:5432/langflow_runtime
```

주의:

* 기존 PVC가 있으면 `POSTGRES_DB` 변경이 자동 반영되지 않을 수 있다.
* 새 DB가 필요하면 직접 `CREATE DATABASE`를 수행하거나 PVC를 초기화한다.

## 16.3 Runtime Deployment와 Job env 중복 방지

Deployment와 Job에 동일한 env가 필요하다.

이때 env를 각각 복붙하면 나중에 차이가 생길 수 있다.

권장:

```text
공통 env helper template 작성
Deployment와 PreSync Job에서 동일 helper include
```

## 16.4 Job 재실행 정책

이번 테스트는 우선 `runOnce: true` 기준이다.

즉, 성공한 Job을 남겨서 다음 Sync에서 재실행되지 않는지 확인한다.

Sync마다 재실행하려면 다음 annotation을 사용한다.

```yaml
argocd.argoproj.io/hook-delete-policy: BeforeHookCreation,HookSucceeded
```

운영 판단:

| 방식             | 장점                  | 단점                               |
| -------------- | ------------------- | -------------------------------- |
| 최초 1회 실행       | DB 초기화 반복 방지        | Hook Job 잔존으로 OutOfSync 여부 확인 필요 |
| Sync마다 실행      | 항상 readiness 선검증 가능 | 매 Sync마다 Langflow 1회 기동 비용 발생    |
| idempotent Job | 가장 안정적              | 구현 복잡도 증가                        |

장기적으로는 재실행되어도 안전한 idempotent Job이 가장 좋다.

---

## 17. 리스크와 대응

| 리스크                             | 설명                                            | 대응                                    |
| ------------------------------- | --------------------------------------------- | ------------------------------------- |
| Langflow command 불일치            | `langflow run --backend-only`가 버전에 따라 다를 수 있음 | image에서 `langflow --help` 확인          |
| `/health_check` 응답 구조 차이        | db/chat/status field가 다를 수 있음                 | 실제 응답 보고 Python script 수정             |
| curl 없음                         | Runtime image에 curl이 없을 수 있음                  | Python urllib 사용                      |
| PostgreSQL PVC 재사용              | Secret 변경 후에도 DB 초기화가 다시 안 됨                  | PVC 삭제 또는 직접 SQL 수행                   |
| PreSync Job과 Deployment env 불일치 | Job은 성공하지만 Runtime은 실패 가능                     | 공통 env helper 사용                      |
| Helm install로 PreSync 검증 착각     | Argo CD hook은 Argo CD Sync에서 의미 있음            | 최종 검증은 Argo CD로 수행                    |
| Job이 남아 OutOfSync 발생            | runOnce 방식의 부작용 가능                            | Argo CD UI 확인 후 hook-delete-policy 조정 |
| `/health_check` 한계              | 전체 업무 초기화 보장 아님                               | 필요 시 추가 API/DB 검증 추가                  |

---

## 18. 완료 기준

이 SDD의 완료 기준은 다음과 같다.

1. `langflow-test` namespace가 생성된다.
2. PostgreSQL Secret/PVC/Deployment/Service가 생성된다.
3. `psql select 1` 테스트가 성공한다.
4. Runtime values에 PostgreSQL DB URL이 설정된다.
5. Runtime Deployment에 DB env가 주입된다.
6. PreSync Job이 Runtime Deployment와 동일 image/env/command 기준으로 구성된다.
7. PreSync Job에서 Langflow가 1회 기동된다.
8. Python urllib 기반 `/health_check` polling이 성공한다.
9. Job 성공 후 Runtime replicas >= 2가 기동된다.
10. Runtime 로그에서 DB 초기화 충돌 오류가 발생하지 않는다.
11. PreSync Job 없는 경우와 비교 테스트가 가능하다.

---

## 19. Codex 작업 지시용 프롬프트

```text
Role:
You are a senior platform engineer. Modify an existing Langflow Helm chart workspace to support a Runtime PreSync DB initialization Job and provide Kubernetes manifests/commands for a test PostgreSQL in k3s.

Context:
A k3s cluster already exists. We need to create a PostgreSQL instance in namespace langflow-test and connect Langflow Runtime to it. The existing Langflow Helm chart workspace already has a Runtime Helm template. We need to add a PreSync Job to the Runtime chart. The Job should be configured as similarly as possible to the Runtime Deployment manifest.

Goal:
Implement the required manifests, values, and Helm templates so that Langflow Runtime can use the PostgreSQL created in namespace langflow-test and a PreSync Job can start Langflow once, check /health_check, then exit before the real Runtime Deployment starts.

Tasks:
1. Add commands or manifests to create namespace langflow-test.
2. Add commands or manifests to deploy PostgreSQL 16 in langflow-test.
   - Secret: POSTGRES_DB=langflow, POSTGRES_USER=langflow, POSTGRES_PASSWORD=langflow
   - PVC: 2Gi, ReadWriteOnce
   - Deployment: postgres:16
   - Service: langflow-postgres, ClusterIP, port 5432
3. Add a psql test command:
   - psql -h langflow-postgres -U langflow -d langflow -c "select 1;"
4. Update Runtime values to connect to PostgreSQL:
   - postgresql://langflow:langflow@langflow-postgres:5432/langflow
5. Add or update Runtime DB Secret template.
6. Ensure Runtime Deployment uses the DB URL through LANGFLOW_DATABASE_URL.
7. Add Runtime PreSync Job template.
   - annotation: argocd.argoproj.io/hook: PreSync
   - sync-wave: -1
   - use the same Runtime image repository/tag/pullPolicy
   - use the same DB env as Runtime Deployment
   - use the same Langflow command as Runtime Deployment if possible
   - start Langflow in background
   - do not depend on curl
   - create a Python urllib.request script to call http://127.0.0.1:7860/health_check
   - check db == ok and optionally chat == ok
   - on success, stop Langflow and exit 0
   - on timeout/failure, stop Langflow and exit 1
   - use trap cleanup to stop the background process
8. Add values:
   - runtime.presyncJob.enabled=true
   - runtime.presyncJob.runOnce=true
   - runtime.presyncJob.healthCheck.url=http://127.0.0.1:7860/health_check
   - runtime.presyncJob.healthCheck.maxRetry=60
   - runtime.presyncJob.healthCheck.sleepSec=3
   - runtime.presyncJob.healthCheck.requireChatOk=false
9. Add helper template if useful so Runtime Deployment and PreSync Job share the same env configuration.
10. Add validation commands:
   - helm template
   - helm upgrade --install
   - kubectl logs job/<job-name>
   - kubectl get pods -n langflow-test
11. Explain that Helm install is useful for chart validation, but Argo CD Sync is required to validate PreSync ordering.
12. Include extra steps for creating additional DB/database/schema if PVC already exists or if a different DB name is required.

Important:
- Do not create a new k3s cluster.
- Do not create Docker Compose.
- Assume an existing Helm chart workspace.
- Keep the PostgreSQL setup simple for test purpose.
- Prefer Secret-based DB URL injection.
- Avoid duplicating env definitions by using helper templates if possible.
```

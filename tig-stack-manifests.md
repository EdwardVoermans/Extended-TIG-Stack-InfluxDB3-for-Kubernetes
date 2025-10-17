##################################################################################################################################
# Manifest Name : tig-stack-manifests.yaml
# Requirements  : Conducted through k3s-deploy-tig.sh
# Purpose       : Specifically developed for Internal Usage [tig-influx.test - self signed TLS Certificate chain]
# Author        : Edward Voermans [ edward@voermans.com ]
# Created On    : 01-10-2025
# Last Update   : 15-10-2025
# Version       : 1.01
##################################################################################################################################
---
# 1. NAMESPACE
apiVersion: v1
kind: Namespace
metadata:
  name: CHANGE_THIS_TO_NAMESPACE

---
# 2. SECRETS - Store sensitive credentials
apiVersion: v1
kind: Secret
metadata:
  name: tig-credentials
  namespace: CHANGE_THIS_TO_NAMESPACE
type: Opaque
stringData:
  influxdb-token: "apiv3_CHANGE_THIS_TO_SECURE_GENERATED_TOKEN"
  grafana-admin-password: "CHANGE_THIS_TO_SECURE_PASSWORD"

---
# 3. TLS SECRET - Self-signed certificate
apiVersion: v1
kind: Secret
metadata:
  name: tig-tls-cert
  namespace: CHANGE_THIS_TO_NAMESPACE
type: kubernetes.io/tls
data:
  tls.crt: CERT_BASE64_PLACEHOLDER
  tls.key: KEY_BASE64_PLACEHOLDER

---
# 4. CONFIGMAP - Environment Variables
apiVersion: v1
kind: ConfigMap
metadata:
  name: tig-env-config
  namespace: CHANGE_THIS_TO_NAMESPACE
data:
  TLD_DOMAIN: "CHANGE_THIS_TO_DOMAIN"
  TIMEOUT: "120"
  HEALTH_CHECK_INTERVAL: "5"
  INFLUXDB_HTTP_PORT: "8181"
  INFLUXDB_HOST: "tig-influxdb"
  INFLUXDB_ORG: "CHANGE_THIS_TO_DOMAIN"
  INFLUXDB_BUCKET: "local_system"
  INFLUXDB_NODE_ID: "writer1"
  GRAFANA_HOST: "tig-grafana"
  GRAFANA_PORT: "3000"
  GRAFANA_ADMIN_USER: "admin"
  GRAFANA_SA_NAME: "tig-grafana-sa"
  GRAFANA_TOKEN_NAME: "tig-grafana-sa-token"
  TELEGRAF_HOST: "tig-telegraf"
  TELEGRAF_COLLECTION_INTERVAL: "10s"
  INFLUXDB_EXPLORER_HOST: "tig-explorer"
  INFLUXDB_EXPLORER_PORT: "80"
  URL_GRAFANA: "tig-grafana.CHANGE_THIS_TO_DOMAIN"
  URL_INFLUXDB_EXPLORER: "tig-explorer.CHANGE_THIS_TO_DOMAIN"

---
# 5. CONFIGMAP - InfluxDB Token File
apiVersion: v1
kind: ConfigMap
metadata:
  name: influxdb-token-config
  namespace: CHANGE_THIS_TO_NAMESPACE
data:
  auto-admin-token.json: |
    {
      "token": "apiv3_CHANGE_THIS_TO_SECURE_GENERATED_TOKEN",
      "name": "_admin",
      "expiry_millis": 3513625132923
    }

---
# 6. CONFIGMAP - Initialization Scripts
apiVersion: v1
kind: ConfigMap
metadata:
  name: init-scripts
  namespace: CHANGE_THIS_TO_NAMESPACE
data:
  wrapper.sh: |
    #!/bin/sh
    set -e
    echo "Running first script... Create initial InfluxDB Database."
    /scripts/create-database.sh

    echo "Running second script... Create Grafana SA and Token."
    /scripts/grafana-token.sh

    echo "✓ Scripts creation process completed successfully"

  create-database.sh: |
    #!/bin/sh
    set -e

    install_required_tools() {
        echo "Checking for required tools..."
        if ! command -v curl >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
            echo "Installing required tools..."
            apk add --no-cache curl jq
            echo "Required tools installed successfully"
        else
            echo "Required tools already available"
        fi
        return 0
    }

    extract_token() {
        local token_file="$1"
        echo "Extracting authentication token..."
        if [ ! -f "$token_file" ]; then
            echo "ERROR: Token file not found at $token_file"
            return 1
        fi
        TOKEN=$(jq -r '.token' "$token_file" 2>/dev/null)
        if [ -z "$TOKEN" ] || [ "$TOKEN" = "null" ]; then
            echo "ERROR: Could not extract valid token from $token_file"
            return 1
        fi
        echo "Token extracted successfully"
        return 0
    }

    wait_for_influxdb() {
        local host="$1"
        local port="$2"
        local timeout="$3"
        local check_interval="$4"
        local token="$5"

        echo "Waiting for InfluxDB to be ready..."
        local elapsed=0

        while [ $elapsed -lt $timeout ]; do
            if curl -sf -H "Authorization: Bearer $token" "http://${host}:${port}/health" >/dev/null 2>&1; then
                echo "InfluxDB is ready! (took ${elapsed}s)"
                return 0
            fi
            echo "InfluxDB not ready yet, waiting... (${elapsed}s elapsed)"
            sleep $check_interval
            elapsed=$((elapsed + check_interval))
        done

        echo "ERROR: InfluxDB failed to become ready within ${timeout} seconds"
        return 1
    }

    create_database() {
        local host="$1"
        local port="$2"
        local database="$3"
        local token="$4"

        echo "Creating database '$database'..."

        local response=$(curl -s -w "\n%{http_code}" \
            -X POST \
            -H "Authorization: Token $token" \
            -H "Content-Type: application/json" \
            -d "{\"db\": \"$database\"}" \
            "http://${host}:${port}/api/v3/configure/database")

        local http_code=$(echo "$response" | tail -n1)
        local response_body=$(echo "$response" | sed '$d')

        case $http_code in
            200|201)
                echo "✓ Database '$database' created successfully"
                [ -n "$response_body" ] && echo "Response: $response_body"
                return 0
                ;;
            409)
                echo "ℹ Database '$database' already exists - no action needed"
                return 0
                ;;
            401|403)
                echo "ERROR: Authentication failed. Check token validity."
                return 1
                ;;
            *)
                echo "ERROR: Failed to create database. HTTP Code: $http_code"
                echo "Response: $response_body"
                return 1
                ;;
        esac
    }

    main() {
        echo "Starting InfluxDB database creation process..."
        echo "Target: ${INFLUXDB_HOST}:${INFLUXDB_HTTP_PORT}"
        echo "Database: ${INFLUXDB_BUCKET}"

        if ! install_required_tools; then
            exit 1
        fi

        if ! extract_token "/etc/influxdb3/auto-admin-token.json"; then
            exit 1
        fi

        if ! wait_for_influxdb "$INFLUXDB_HOST" "$INFLUXDB_HTTP_PORT" "$TIMEOUT" "$HEALTH_CHECK_INTERVAL" "$TOKEN"; then
            exit 1
        fi

        if ! create_database "$INFLUXDB_HOST" "$INFLUXDB_HTTP_PORT" "$INFLUXDB_BUCKET" "$TOKEN"; then
            exit 1
        fi

        echo "✓ Database creation process completed successfully"
    }

    main

  grafana-token.sh: |
    #!/bin/sh
    set -e

    install_required_tools() {
        echo "Checking for required tools..."
        if ! command -v curl >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
            echo "Installing required tools..."
            apk add --no-cache curl jq
            echo "Required tools installed successfully"
        else
            echo "Required tools already available"
        fi
        return 0
    }

    wait_for_grafana() {
        echo "Waiting for Grafana to be healthy at http://${GRAFANA_HOST}:${GRAFANA_PORT}"
        ELAPSED=0

        while [ $ELAPSED -lt ${TIMEOUT} ]; do
            if curl -sf "http://${GRAFANA_HOST}:${GRAFANA_PORT}/api/health" >/dev/null 2>&1; then
                echo "Grafana is ready! (took ${ELAPSED}s)"
                return 0
            fi
            echo "Grafana not ready yet, waiting... (${ELAPSED}s elapsed)"
            sleep ${HEALTH_CHECK_INTERVAL}
            ELAPSED=$((ELAPSED + HEALTH_CHECK_INTERVAL))
        done

        echo "ERROR: Grafana failed to become healthy after ${TIMEOUT} seconds"
        return 1
    }

    create_grafana_service_account() {
        echo "Creating Grafana Service Account..." >&2
        echo "Service Account Name: ${GRAFANA_SA_NAME}" >&2
        echo "Grafana Host: ${GRAFANA_HOST}:${GRAFANA_PORT}" >&2

        echo "Testing authentication..." >&2
        AUTH_TEST=$(curl -s -w "%{http_code}" -o /dev/null \
            -u admin:${GRAFANA_ADMIN_PASSWORD} \
            http://${GRAFANA_HOST}:${GRAFANA_PORT}/api/org)

        if [ "$AUTH_TEST" != "200" ]; then
            echo "ERROR: Authentication failed (HTTP $AUTH_TEST)" >&2
            return 1
        fi
        echo "Authentication successful" >&2

        echo "Creating service account..." >&2
        SA_RESPONSE=$(curl -s -w "HTTP_CODE:%{http_code}" \
            -H "Content-Type: application/json" \
            -H "Accept: application/json" \
            -u admin:${GRAFANA_ADMIN_PASSWORD} \
            -X POST \
            --data "{\"name\":\"${GRAFANA_SA_NAME}\",\"role\":\"Admin\",\"isDisabled\":false}" \
            http://${GRAFANA_HOST}:${GRAFANA_PORT}/api/serviceaccounts)

        HTTP_CODE=$(echo "$SA_RESPONSE" | grep -o 'HTTP_CODE:[0-9]*' | cut -d: -f2)
        SA_RESPONSE_BODY=$(echo "$SA_RESPONSE" | sed 's/HTTP_CODE:[0-9]*$//')

        echo "HTTP Status Code: $HTTP_CODE" >&2

        if [ "$HTTP_CODE" != "201" ]; then
            # Check if it already exists
            if echo "$SA_RESPONSE_BODY" | grep -q "service account.*already exists"; then
                echo "Service account already exists, fetching ID..." >&2
                # Get existing SA ID
                EXISTING_SA=$(curl -s \
                    -u admin:${GRAFANA_ADMIN_PASSWORD} \
                    "http://${GRAFANA_HOST}:${GRAFANA_PORT}/api/serviceaccounts/search?query=${GRAFANA_SA_NAME}")
                SA_ID=$(echo "$EXISTING_SA" | grep -o '"id":[0-9]*' | head -1 | cut -d: -f2)
                if [ -n "$SA_ID" ]; then
                    echo "Found existing service account with ID: $SA_ID" >&2
                    echo "$SA_ID"
                    return 0
                fi
            fi
            echo "ERROR: Service account creation failed with HTTP $HTTP_CODE" >&2
            echo "Response: $SA_RESPONSE_BODY" >&2
            return 1
        fi

        SA_ID=$(echo "$SA_RESPONSE_BODY" | jq -r .id)

        if [ "$SA_ID" = "null" ] || [ -z "$SA_ID" ]; then
            echo "ERROR: Failed to get service account ID" >&2
            return 1
        fi

        echo "Created service account with ID: $SA_ID" >&2
        echo "$SA_ID"
        return 0
    }

    main() {
        echo "Starting Grafana Service Account creation process..."

        if ! install_required_tools; then
            exit 1
        fi

        if ! wait_for_grafana; then
            exit 1
        fi

        SA_ID=$(create_grafana_service_account)
        SA_CREATE_RESULT=$?

        if [ $SA_CREATE_RESULT -ne 0 ]; then
            echo "Service account creation failed"
            exit 1
        fi

        echo "✓ Service Account created/verified with ID: $SA_ID"
        echo "Note: Token will be created by deployment script"
        exit 0
    }

    main

---
# 7. CONFIGMAP - Telegraf Configuration
apiVersion: v1
kind: ConfigMap
metadata:
  name: telegraf-config
  namespace: CHANGE_THIS_TO_NAMESPACE
data:
  telegraf.conf: |
    [agent]
      interval = "10s"
      flush_interval = "10s"
      hostname = "tig-telegraf"
      round_interval = true
      metric_batch_size = 1000
      metric_buffer_limit = 10000

    [[inputs.cpu]]
      percpu = true
      totalcpu = true
      collect_cpu_time = false
      report_active = true

    [[inputs.mem]]

    [[inputs.disk]]
      mount_points = ["/"]
      ignore_fs = ["tmpfs", "devtmpfs", "devfs", "iso9660", "overlay", "aufs", "squashfs"]

    [[inputs.diskio]]
      devices = ["sda", "sdb", "nvme0n1"]
      skip_serial_number = true

    [[inputs.net]]
      interfaces = ["eth*", "en*"]
      ignore_protocol_stats = false

    [[inputs.system]]

    [[inputs.kubernetes]]
      url = "https://$HOSTIP:10250"
      bearer_token = "/var/run/secrets/kubernetes.io/serviceaccount/token"
      insecure_skip_verify = true

    [[outputs.influxdb_v2]]
      urls = ["http://tig-influxdb:8181"]
      token = "$INFLUXDB_TOKEN"
      organization = "eCHANGE_THIS_TO_DOMAIN"
      bucket = "local_system"
      timeout = "5s"
      content_encoding = "gzip"

---
# 8. CONFIGMAP - Grafana Configuration
apiVersion: v1
kind: ConfigMap
metadata:
  name: grafana-config
  namespace: CHANGE_THIS_TO_NAMESPACE
data:
  grafana.ini: |
    [server]
    protocol = http
    http_port = 3000
    domain = tig-grafana.CHANGE_THIS_TO_DOMAIN
    root_url = https://tig-grafana.CHANGE_THIS_TO_DOMAIN

    [security]
    admin_user = admin
    cookie_secure = false
    cookie_samesite = lax

    [users]
    allow_sign_up = false
    default_theme = dark

    [auth.anonymous]
    enabled = false

    [auth.basic]
    enabled = true

    [log]
    mode = console
    level = warn

---
# 9. CONFIGMAP - Grafana Datasource Provisioning
apiVersion: v1
kind: ConfigMap
metadata:
  name: grafana-datasource
  namespace: CHANGE_THIS_TO_NAMESPACE
data:
  influxdb.yaml: |
    apiVersion: 1
    datasources:
      - name: tig-influxdb3
        type: influxdb
        access: proxy
        orgId: 1
        # url: http://tig-influxdb-0:8181
        url: http://tig-influxdb-0.tig-influxdb.CHANGE_THIS_TO_NAMESPACE.svc.cluster.local:8181
        withCredentials: false
        isDefault: true
        jsonData:
          dbName: local_system
          httpHeaderName1: Bearer
          httpMode: GET
          insecureGrpc: true
          version: SQL
          organization: eCHANGE_THIS_TO_DOMAIN
          defaultBucket: local_system
          tlsSkipVerify: true
        secureJsonData:
          token: $INFLUXDB_TOKEN
        editable: true

---
# 10. CONFIGMAP - Grafana Dashboard Provisioning
apiVersion: v1
kind: ConfigMap
metadata:
  name: grafana-dashboards
  namespace: CHANGE_THIS_TO_NAMESPACE
data:
  dashboards.yaml: |
    apiVersion: 1
    providers:
      - name: 'default'
        orgId: 1
        folder: ''
        type: file
        disableDeletion: false
        editable: true
        updateIntervalSeconds: 30
        allowUiUpdates: true
        options:
          path: /etc/grafana/provisioning/dashboards

  system-monitoring.json: |
    {
    "annotations": {
        "list": [
        {
            "builtIn": 1,
            "datasource": {
            "type": "grafana",
            "uid": "-- Grafana --"
            },
            "enable": true,
            "hide": true,
            "iconColor": "rgba(0, 211, 255, 1)",
            "name": "Annotations & Alerts",
            "type": "dashboard"
        }
        ]
    },
    "editable": true,
    "fiscalYearStartMonth": 0,
    "graphTooltip": 0,
    "id": 1,
    "links": [],
    "panels": [
        {
        "datasource": {
            "type": "influxdb",
            "uid": "P1E71DEBAF15C8614"
        },
        "fieldConfig": {
            "defaults": {
            "color": {
                "mode": "palette-classic"
            },
            "custom": {
                "axisBorderShow": false,
                "axisCenteredZero": false,
                "axisColorMode": "text",
                "axisLabel": "",
                "axisPlacement": "auto",
                "barAlignment": 0,
                "barWidthFactor": 0.6,
                "drawStyle": "line",
                "fillOpacity": 0,
                "gradientMode": "none",
                "hideFrom": {
                "legend": false,
                "tooltip": false,
                "viz": false
                },
                "insertNulls": false,
                "lineInterpolation": "linear",
                "lineWidth": 1,
                "pointSize": 5,
                "scaleDistribution": {
                "type": "linear"
                },
                "showPoints": "auto",
                "spanNulls": false,
                "stacking": {
                "group": "A",
                "mode": "none"
                },
                "thresholdsStyle": {
                "mode": "off"
                }
            },
            "mappings": [],
            "thresholds": {
                "mode": "absolute",
                "steps": [
                {
                    "color": "green",
                    "value": 0
                },
                {
                    "color": "red",
                    "value": 80
                }
                ]
            }
            },
            "overrides": []
        },
        "gridPos": {
            "h": 8,
            "w": 12,
            "x": 0,
            "y": 0
        },
        "id": 1,
        "options": {
            "legend": {
            "calcs": [],
            "displayMode": "list",
            "placement": "bottom",
            "showLegend": true
            },
            "tooltip": {
            "hideZeros": false,
            "mode": "single",
            "sort": "none"
            }
        },
        "pluginVersion": "12.1.1",
        "targets": [
            {
            "dataset": "iox",
            "datasource": {
                "type": "influxdb",
                "uid": "P1E71DEBAF15C8614"
            },
            "editorMode": "code",
            "format": "table",
            "rawQuery": true,
            "rawSql": "SELECT \"cpu\", \"usage_user\", \"time\" FROM \"cpu\" WHERE \"time\" >= $__timeFrom AND \"time\" <= $__timeTo AND \"cpu\" = 'cpu0'",
            "refId": "A",
            "sql": {
                "columns": [
                {
                    "parameters": [],
                    "type": "function"
                }
                ],
                "groupBy": [
                {
                    "property": {
                    "type": "string"
                    },
                    "type": "groupBy"
                }
                ]
            }
            },
            {
            "dataset": "iox",
            "datasource": {
                "type": "influxdb",
                "uid": "P1E71DEBAF15C8614"
            },
            "editorMode": "code",
            "format": "table",
            "hide": false,
            "rawQuery": true,
            "rawSql": "SELECT \"cpu\", \"usage_user\", \"time\" FROM \"cpu\" WHERE \"time\" >= $__timeFrom AND \"time\" <= $__timeTo AND \"cpu\" = 'cpu1'",
            "refId": "B",
            "sql": {
                "columns": [
                {
                    "parameters": [],
                    "type": "function"
                }
                ],
                "groupBy": [
                {
                    "property": {
                    "type": "string"
                    },
                    "type": "groupBy"
                }
                ]
            }
            },
            {
            "dataset": "iox",
            "datasource": {
                "type": "influxdb",
                "uid": "P1E71DEBAF15C8614"
            },
            "editorMode": "code",
            "format": "table",
            "hide": false,
            "rawQuery": true,
            "rawSql": "SELECT \"cpu\", \"usage_user\", \"time\" FROM \"cpu\" WHERE \"time\" >= $__timeFrom AND \"time\" <= $__timeTo AND \"cpu\" = 'cpu2'",
            "refId": "C",
            "sql": {
                "columns": [
                {
                    "parameters": [],
                    "type": "function"
                }
                ],
                "groupBy": [
                {
                    "property": {
                    "type": "string"
                    },
                    "type": "groupBy"
                }
                ]
            }
            }
        ],
        "title": "CPU",
        "type": "timeseries"
        }
    ],
    "preload": false,
    "schemaVersion": 41,
    "tags": [],
    "templating": {
        "list": []
    },
    "time": {
        "from": "now-1h",
        "to": "now"
    },
    "timepicker": {},
    "timezone": "browser",
    "title": "TIG-Stack using InfluxDB3",
    "uid": "b8099355-ee76-46b4-8fde-c7ccf83c93b9",
    "version": 3
    }
---
# 11. CONFIGMAP - InfluxDB Explorer Configuration
apiVersion: v1
kind: ConfigMap
metadata:
  name: influx-explorer-config
  namespace: CHANGE_THIS_TO_NAMESPACE
data:
  config.json: |
    {
      "DEFAULT_INFLUX_SERVER": "http://tig-influxdb:8181",
      "DEFAULT_INFLUX_DATABASE": "local_system",
      "DEFAULT_API_TOKEN": "$INFLUXDB_TOKEN",
      "DEFAULT_SERVER_NAME": "tig-influxdb3"
    }

---
# 12. PERSISTENT VOLUME CLAIMS
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: grafana-data-dev
  namespace: CHANGE_THIS_TO_NAMESPACE
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: nfs-client
  resources:
    requests:
      storage: 10Gi

---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: influxdb-data-dev
  namespace: CHANGE_THIS_TO_NAMESPACE
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: nfs-client
  resources:
    requests:
      storage: 50Gi

---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: influx-explorer-dev
  namespace: CHANGE_THIS_TO_NAMESPACE
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: nfs-client
  resources:
    requests:
      storage: 5Gi

---
# 13. STATEFULSET - InfluxDB3
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: tig-influxdb
  namespace: CHANGE_THIS_TO_NAMESPACE
spec:
  serviceName: tig-influxdb
  replicas: 1
  selector:
    matchLabels:
      app: tig-influxdb
  template:
    metadata:
      labels:
        app: tig-influxdb
    spec:
      securityContext:
        fsGroup: 1000
        runAsUser: 1000
        runAsNonRoot: true
      containers:
      - name: influxdb
        image: quay.io/influxdb/influxdb3-core:latest
        args:
          - serve
          - --node-id=writer1
          - --object-store=file
          - --data-dir=/var/lib/influxdb3
          - --plugin-dir=/var/lib/influxdb3/plugins
          - --admin-token-file=/etc/influxdb3/auto-admin-token.json
        ports:
        - containerPort: 8181
          name: http
        env:
        - name: INFLUXDB_ORG
          value: "eCHANGE_THIS_TO_DOMAIN"
        - name: TZ
          value: "Europe/Amsterdam"
        volumeMounts:
        - name: data
          mountPath: /var/lib/influxdb3
        - name: token-config
          mountPath: /etc/influxdb3
          readOnly: true
        livenessProbe:
          httpGet:
            path: /health
            port: 8181
            httpHeaders:
            - name: Authorization
              value: Bearer apiv3_CHANGE_THIS
          initialDelaySeconds: 60
          periodSeconds: 30
        readinessProbe:
          httpGet:
            path: /health
            port: 8181
            httpHeaders:
            - name: Authorization
              value: Bearer apiv3_CHANGE_THIS
          initialDelaySeconds: 30
          periodSeconds: 10
        resources:
          requests:
            memory: "512Mi"
            cpu: "250m"
          limits:
            memory: "2Gi"
            cpu: "1000m"
      volumes:
      - name: token-config
        configMap:
          name: influxdb-token-config
      - name: data
        persistentVolumeClaim:
          claimName: influxdb-data-dev

---
# 14. SERVICE - InfluxDB
apiVersion: v1
kind: Service
metadata:
  name: tig-influxdb
  namespace: CHANGE_THIS_TO_NAMESPACE
spec:
  selector:
    app: tig-influxdb
  ports:
  - port: 8181
    targetPort: 8181
    name: http
  clusterIP: None

---
# 15. JOB - Database and Grafana Initialization
apiVersion: batch/v1
kind: Job
metadata:
  name: tig-init
  namespace: CHANGE_THIS_TO_NAMESPACE
spec:
  ttlSecondsAfterFinished: 300
  template:
    spec:
      restartPolicy: OnFailure
      containers:
      - name: init-scripts
        image: alpine:3.18
        workingDir: /scripts
        command: ["/bin/sh", "wrapper.sh"]
        envFrom:
        - configMapRef:
            name: tig-env-config
        env:
        - name: INFLUXDB_TOKEN
          valueFrom:
            secretKeyRef:
              name: tig-credentials
              key: influxdb-token
        - name: GRAFANA_ADMIN_PASSWORD
          valueFrom:
            secretKeyRef:
              name: tig-credentials
              key: grafana-admin-password
        volumeMounts:
        - name: scripts
          mountPath: /scripts
        - name: token-config
          mountPath: /etc/influxdb3
        - name: output
          mountPath: /app
      volumes:
      - name: scripts
        configMap:
          name: init-scripts
          defaultMode: 0755
      - name: token-config
        configMap:
          name: influxdb-token-config
      - name: output
        emptyDir: {}

---
# 16. DEPLOYMENT - Grafana
apiVersion: apps/v1
kind: Deployment
metadata:
  name: tig-grafana
  namespace: CHANGE_THIS_TO_NAMESPACE
spec:
  replicas: 1
  selector:
    matchLabels:
      app: tig-grafana
  template:
    metadata:
      labels:
        app: tig-grafana
    spec:
      securityContext:
        fsGroup: 472
        runAsUser: 472
        runAsNonRoot: true
      containers:
      - name: grafana
        image: grafana/grafana:latest
        ports:
        - containerPort: 3000
          name: http
        env:
        - name: GF_SECURITY_ADMIN_PASSWORD
          valueFrom:
            secretKeyRef:
              name: tig-credentials
              key: grafana-admin-password
        - name: GF_USERS_ALLOW_SIGN_UP
          value: "false"
        - name: GF_SERVER_DOMAIN
          value: "tig-grafana.CHANGE_THIS_TO_DOMAIN"
        - name: GF_SERVER_ROOT_URL
          value: "https://tig-grafana.CHANGE_THIS_TO_DOMAIN"
        - name: GF_LOG_LEVEL
          value: "warn"
        - name: TZ
          value: "Europe/Amsterdam"
        volumeMounts:
        - name: data
          mountPath: /var/lib/grafana
        - name: config
          mountPath: /etc/grafana/grafana.ini
          subPath: grafana.ini
        - name: datasources
          mountPath: /etc/grafana/provisioning/datasources
        - name: dashboards-config
          mountPath: /etc/grafana/provisioning/dashboards
        livenessProbe:
          httpGet:
            path: /api/health
            port: 3000
          initialDelaySeconds: 30
          periodSeconds: 30
        readinessProbe:
          httpGet:
            path: /api/health
            port: 3000
          initialDelaySeconds: 10
          periodSeconds: 10
        resources:
          requests:
            memory: "128Mi"
            cpu: "100m"
          limits:
            memory: "512Mi"
            cpu: "500m"
      volumes:
      - name: data
        persistentVolumeClaim:
          claimName: grafana-data-dev
      - name: config
        configMap:
          name: grafana-config
      - name: datasources
        configMap:
          name: grafana-datasource
      - name: dashboards-config
        configMap:
          name: grafana-dashboards

---
# 17. SERVICE - Grafana
apiVersion: v1
kind: Service
metadata:
  name: tig-grafana
  namespace: CHANGE_THIS_TO_NAMESPACE
spec:
  selector:
    app: tig-grafana
  ports:
  - port: 3000
    targetPort: 3000
    name: http

---
# 18. DEPLOYMENT - InfluxDB Explorer
apiVersion: apps/v1
kind: Deployment
metadata:
  name: tig-explorer
  namespace: CHANGE_THIS_TO_NAMESPACE
spec:
  replicas: 1
  selector:
    matchLabels:
      app: tig-explorer
  template:
    metadata:
      labels:
        app: tig-explorer
    spec:
      containers:
      - name: explorer
        image: quay.io/influxdb/influxdb3-explorer:latest
        args: ["--mode=admin"]
        ports:
        - containerPort: 80
          name: http
        env:
        - name: TZ
          value: "Europe/Amsterdam"
        volumeMounts:
        - name: config
          mountPath: /app-root/config
        - name: db
          mountPath: /db
        resources:
          requests:
            memory: "64Mi"
            cpu: "50m"
          limits:
            memory: "256Mi"
            cpu: "250m"
      volumes:
      - name: config
        configMap:
          name: influx-explorer-config
      - name: db
        persistentVolumeClaim:
          claimName: influx-explorer-dev

---
# 19. SERVICE - InfluxDB Explorer
apiVersion: v1
kind: Service
metadata:
  name: tig-explorer
  namespace: CHANGE_THIS_TO_NAMESPACE
spec:
  selector:
    app: tig-explorer
  ports:
  - port: 80
    targetPort: 80
    name: http

---
# 20. DEPLOYMENT - Telegraf
apiVersion: apps/v1
kind: Deployment
metadata:
  name: tig-telegraf
  namespace: CHANGE_THIS_TO_NAMESPACE
spec:
  replicas: 1
  selector:
    matchLabels:
      app: tig-telegraf
  template:
    metadata:
      labels:
        app: tig-telegraf
    spec:
      serviceAccountName: telegraf
      containers:
      - name: telegraf
        image: telegraf:1.28-alpine
        env:
        - name: INFLUXDB_TOKEN
          valueFrom:
            secretKeyRef:
              name: tig-credentials
              key: influxdb-token
        - name: HOSTNAME
          valueFrom:
            fieldRef:
              fieldPath: spec.nodeName
        - name: HOSTIP
          valueFrom:
            fieldRef:
              fieldPath: status.hostIP
        volumeMounts:
        - name: config
          mountPath: /etc/telegraf/telegraf.conf
          subPath: telegraf.conf
        securityContext:
          capabilities:
            add:
            - NET_ADMIN
            - SYS_ADMIN
            - DAC_READ_SEARCH
        resources:
          requests:
            memory: "128Mi"
            cpu: "100m"
          limits:
            memory: "512Mi"
            cpu: "500m"
      volumes:
      - name: config
        configMap:
          name: telegraf-config

---
# 21. SERVICEACCOUNT - Telegraf
apiVersion: v1
kind: ServiceAccount
metadata:
  name: telegraf
  namespace: CHANGE_THIS_TO_NAMESPACE

---
# 22. CLUSTERROLE - Telegraf
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: telegraf
rules:
- apiGroups: [""]
  resources:
  - nodes
  - nodes/stats
  - nodes/proxy
  - services
  - endpoints
  - pods
  verbs: ["get", "list"]

---
# 23. CLUSTERROLEBINDING - Telegraf
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: telegraf
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: telegraf
subjects:
- kind: ServiceAccount
  name: telegraf
  namespace: CHANGE_THIS_TO_NAMESPACE

---
# 24. INGRESS - Grafana
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: tig-grafana
  namespace: CHANGE_THIS_TO_NAMESPACE
  annotations:
    nginx.ingress.kubernetes.io/ssl-redirect: "true"
spec:
  ingressClassName: nginx
  tls:
  - hosts:
    - tig-grafana.CHANGE_THIS_TO_DOMAIN
    secretName: tig-tls-cert
  rules:
  - host: tig-grafana.CHANGE_THIS_TO_DOMAIN
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: tig-grafana
            port:
              number: 3000

---
# 25. INGRESS - InfluxDB Explorer
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: tig-explorer
  namespace: CHANGE_THIS_TO_NAMESPACE
  annotations:
    nginx.ingress.kubernetes.io/ssl-redirect: "true"
spec:
  ingressClassName: nginx
  tls:
  - hosts:
    - tig-explorer.CHANGE_THIS_TO_DOMAIN
    secretName: tig-tls-cert
  rules:
  - host: tig-explorer.CHANGE_THIS_TO_DOMAIN
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: tig-explorer
            port:
              number: 80
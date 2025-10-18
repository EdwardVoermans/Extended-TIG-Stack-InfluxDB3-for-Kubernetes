# Extended TIG Stack for K3s - Production-Ready Monitoring

A complete Telegraf-InfluxDB3-Grafana (TIG) monitoring stack deployment for Kubernetes (K3S), featuring automated initialization, HTTPS ingress, and persistent storage for comprehensive system monitoring and visualization.
The key of this project is the **automated deployment**. It will setup a kubernetes development environment in minutes instead of hours if not days.

If you are looking for the **Docker version** check this: https://tinyurl.com/5n8ydsr4

## Overview

This project provides a fully automated deployment of a modern monitoring stack on K3s, including:

- **InfluxDB3 Core Edition** - High-performance time-series database
- **Grafana** - Powerful visualization and dashboarding
- **Telegraf** - Metrics collection from Kubernetes and system resources
- **InfluxDB Explorer** - Web-based database management interface

### Key Features

- **One-command deployment** with automated credential generation
- **HTTPS by default** with self-signed certificates
- **Automatic initialization** - Database, tokens and service accounts created automatically
- **Persistent storage** via NFS
- **(semi) Production-ready** with health checks, resource limits, and RBAC
- **Kubernetes-native** metrics collection with Telegraf

## Prerequisites

### K3s Cluster (tested on v1.33.4+k3s1)

This deployment requires a K3s cluster with the following components **already installed**:

| Component | Purpose | Configuration |
|-----------|---------|---------------|
| **MetalLB** | LoadBalancer for bare-metal | IP pool configured |
| **ingress-nginx** | HTTPS ingress controller | `ingressClassName: nginx` |
| **NFS Client Provisioner** | Dynamic PV provisioning | `storageClassName: nfs-client` |
| **DNS Server** | Domain resolution | `*.tig-influx.test` → MetalLB IP |

### Local Tools

- `kubectl` - Configured for your K3s cluster
- `openssl` - Certificate generation
- `curl` - API communication
- `bash` - Script execution
- `sed` - Manifest variable substitution 

### Deployment Flow

```
1. Deployment Script (k3s-deploy-tig.sh)
   ├─ Generate credentials (InfluxDB token, Grafana password)
   ├─ Generate self-signed TLS certificates
   ├─ Update manifest with generated secrets
   └─ Deploy manifest to K3S

2. Kubernetes Resources Created (in order)
   ├─ Namespace: tig-stack-k3s
   ├─ Secrets: credentials, TLS certificate, tokens
   ├─ ConfigMaps: environment vars, scripts, configs
   └─ PersistentVolumeClaims: storage provisioning

3. Application Deployment
   ├─ StatefulSet: InfluxDB (waits for PVC binding)
   ├─ Job: Init scripts (waits for InfluxDB ready)
   │   ├─ Create InfluxDB database
   │   └─ Create Grafana service account
   ├─ Deployments: Grafana, Explorer, Telegraf
   └─ Ingresses: HTTPS endpoints

4. Post-Deployment
   └─ Script creates Grafana SA token via API
       ├─ Saved to .k3s-credentials file
       └─ Stored in K3S secret
```

### Note on step 4.
The final step in the deployment consists of creating a Grafana Service Account Token.
This is done through the Grafan API and thus requires name resolving for your Grafana container https://tig-grafana.YourDomainOfChoice
So this will require you to conduct the following steps on your K3S cluster:
- Determine your LoadBalancer IP: `kubectl get svc -A | grep LoadBalancer` 
- Configure https://tig-grafana.YourDomainOfChoice with the LoadBalancer IP-Address
- Verify 
If the DNS or host file isn't set prior to deployment the Token creation will fail. 


## Quick Start

```bash
# Clone repository
git clone <your-repo-url>
cd tig-stack-k3s
```

### Modify deployemnt / system variable
Look for the variables section in the `k3s-deploy-tig.sh` script and edit the variables as per your own requirement.
```
# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFEST_FILE="${SCRIPT_DIR}/tig-stack-manifests.yaml"
CREDS_FILE="${SCRIPT_DIR}/.k3s-credentials"
CERT_DIR="${SCRIPT_DIR}/certs"
DRY_RUN=false
REGENERATE_CREDS=false
NAMESPACE="tig-stack-k3s-dev"
DOMAIN="tig-influx.test"
```
```bash
# Deploy
chmod +x k3s-deploy-tig.sh
./k3s-deploy-tig.sh
============================================
   TIG Stack K3s Deployment (Dev)
============================================

Checking prerequisites...
✓ Prerequisites OK

Generating credentials...
✓ Generated credentials
InfluxDB Token: apiv3_tYwbdigMIbDy3C...
Grafana Password: MaFj3DJ4NcNAJQK1lyq....

Generating self-signed certificates...
✓ Generated certificates

Creating deployment manifest...
✓ Manifest ready: /home/turingpi/tig-stack-dev/tig-stack-manifests-ready.yaml

Deployment Plan:

  Namespace: tig-stack-k3s-dev
  Domain: tig-influx.test
  Storage: nfs-client
  Ingress: nginx

Resources:
  • 1 Namespace
  • 3 Secrets (credentials, TLS certificate, Grafana Token)
  • 7 ConfigMaps (configs, scripts)
  • 3 PVCs (Grafana, InfluxDB, Explorer - 65Gi total)
  • 1 StatefulSet (InfluxDB)
  • 3 Deployments (Grafana, Explorer, Telegraf)
  • 3 Services
  • 1 Job (initialization)
  • 2 Ingresses (HTTPS via nginx)
  • RBAC for Telegraf

Endpoints:
  • https://tig-grafana.tig-influx.test
  • https://tig-explorer.tig-influx.test

Deploy now? (yes/no):
```
Confirm the next step by either providing 'yes' to continue or 'no' to halt the setup procedure.
Once finished your screen will show the current status of your kubernetes deployment:
```
Current Status:

NAME                            READY   STATUS      RESTARTS   AGE
tig-explorer-58d4ffcd86-bbj8w   1/1     Running     0          72s
tig-grafana-658dcd47fd-zldmt    1/1     Running     0          72s
tig-influxdb-0                  1/1     Running     0          73s
tig-init-9x526                  0/1     Completed   0          73s
tig-telegraf-84894f9565-l6tqx   1/1     Running     0          72s

NAME                  STATUS   VOLUME                                     CAPACITY   ACCESS MODES   STORAGECLASS   VOLUMEATTRIBUTESCLASS   AGE
grafana-data-dev      Bound    pvc-b76ddabf-df79-4d84-a6a9-b1a4f9859a3e   10Gi       RWO            nfs-client     <unset>                 73s
influx-explorer-dev   Bound    pvc-c80ea180-dd95-411c-992a-8f9a972d7058   5Gi        RWO            nfs-client     <unset>                 73s
influxdb-data-dev     Bound    pvc-29f441ff-178e-4369-ac43-e4d22b295890   50Gi       RWO            nfs-client     <unset>                 73s

NAME           CLASS   HOSTS                          ADDRESS         PORTS     AGE
tig-explorer   nginx   tig-explorer.tig-influx.test   192.168.30.32   80, 443   73s
tig-grafana    nginx   tig-grafana.tig-influx.test    192.168.30.32   80, 443   73s
```
**Access your stack:**
- Grafana: https://tig-grafana.tig-influx.test
- Explorer: https://tig-explorer.tig-influx.test

Credentials are in `.k3s-credentials` file and in kubernetes secrets.
```
✓ Grafana Service Account Token created and saved
  Retrieve with: kubectl get secret -n tig-stack-k3s-dev grafana-sa-token -o jsonpath='{.data.token}' | base64 -d

✓ Grafana Admin Password created and saved
  Retrieve with: kubectl get secret -n tig-stack-k3s-dev tig-credentials -o jsonpath='{.data.grafana-admin-password}' | base64 -d
```

## Authors and Credits
- **Author**: Edward Voermans (edward@voermans.com)
- **Credits**: Based on work by Suyash Joshi (sjoshi@influxdata.com)
- **GitHub**: [TIG-Stack-using-InfluxDB-3](https://github.com/InfluxCommunity/TIG-Stack-using-InfluxDB-3)

## License
This project builds upon MIT license.

## Support
For issues and questions:
- Check the troubleshooting section (tbd)
- Contact: edward@voermans.com

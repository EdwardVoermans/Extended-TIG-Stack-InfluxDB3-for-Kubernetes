#!/bin/bash
##################################################################################################################################
# Script Name   : k3s-deploy-tig.sh
# Description   : Deploy TIG stack to K3s cluster with existing infrastructure
# Requirements  : MetalLB, ingress-nginx, nfs-client storage
# Purpose       : Specifically developed for Internal Usage [tig-influx.test - self signed TLS Certificate chain]
# Author        : Edward Voermans [ edward@voermans.com ]
# Created On    : 01-10-2025
# Last Update   : 15-10-2025
# Version       : 1.01
# Usage         : ./k3s-deploy-tig.sh [--dry-run] [--regenerate-creds]
#
# Credits     : Suyash Joshi (sjoshi@influxdata.com) 
#             : Based on Github published https://github.com/InfluxCommunity/TIG-Stack-using-InfluxDB-3/tree/main
#
# Notes       :
#       - Requires tig-stack-manifests.yaml to be present
#       - Run with sudo only if accessing restricted files
#       - Tested on DietPi v9.5.1
#       - Tested on K3S Kubernetes v1.33.4+k3s1
#          
##################################################################################################################################

set -e

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFEST_FILE="${SCRIPT_DIR}/tig-stack-manifests.yaml"
CREDS_FILE="${SCRIPT_DIR}/.k3s-credentials"
CERT_DIR="${SCRIPT_DIR}/certs"
DRY_RUN=false
REGENERATE_CREDS=false
NAMESPACE="tig-stack-k3s-dev"
DOMAIN="tig-influx.test"

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --regenerate-creds)
            REGENERATE_CREDS=true
            shift
            ;;
        -h|--help)
            echo "Usage: $0 [--dry-run] [--regenerate-creds]"
            echo "  --dry-run            Show what would be done"
            echo "  --regenerate-creds   Force regeneration of credentials"
            exit 0
            ;;
        *)
            echo "Unknown parameter: $1"
            exit 1
            ;;
    esac
done

echo -e "${CYAN}============================================${NC}"
echo -e "${CYAN}   TIG Stack K3s Deployment (Dev)         ${NC}"
echo -e "${CYAN}============================================${NC}"
echo ""

##################################################################################################################################
# Check prerequisites
##################################################################################################################################
check_prerequisites() {
    echo -e "${CYAN}Checking prerequisites...${NC}"

    if ! command -v kubectl &> /dev/null; then
        echo -e "${RED}Error: kubectl not installed${NC}"
        exit 1
    fi

    if ! kubectl cluster-info &> /dev/null; then
        echo -e "${RED}Error: Cannot connect to K3s cluster${NC}"
        exit 1
    fi

    if ! command -v openssl &> /dev/null; then
        echo -e "${RED}Error: openssl required${NC}"
        exit 1
    fi

    # Check if nfs-client storageclass exists
    if ! kubectl get storageclass nfs-client &> /dev/null; then
        echo -e "${YELLOW}Warning: nfs-client storageclass not found${NC}"
        echo -e "${YELLOW}Make sure NFS provisioner is deployed${NC}"
    fi

    # Check if ingress-nginx exists
    if ! kubectl get ingressclass nginx &> /dev/null 2>&1; then
        echo -e "${YELLOW}Warning: nginx ingressclass not found${NC}"
        echo -e "${YELLOW}Make sure ingress-nginx is deployed${NC}"
    fi

    if [ ! -f "$MANIFEST_FILE" ]; then
        echo -e "${RED}Error: Manifest file not found: $MANIFEST_FILE${NC}"
        exit 1
    fi

    echo -e "${GREEN}✓ Prerequisites OK${NC}"
    echo ""
}

##################################################################################################################################
# Generate credentials
##################################################################################################################################
generate_credentials() {
    if [ -f "$CREDS_FILE" ] && [ "$REGENERATE_CREDS" = false ]; then
        echo -e "${CYAN}Loading existing credentials...${NC}"
        source "$CREDS_FILE"
        echo -e "${GREEN}✓ Loaded credentials${NC}"
    else
        echo -e "${CYAN}Generating credentials...${NC}"

        INFLUXDB_TOKEN="apiv3_$(openssl rand 74 | base64 | tr -d '=+/' | tr -d '\n')"
        GRAFANA_PASSWORD=$(openssl rand -base64 24 | tr -d '=+/@')

        cat > "$CREDS_FILE" << EOF
# TIG Stack K3s Credentials - Generated $(date)
INFLUXDB_TOKEN="${INFLUXDB_TOKEN}"
GRAFANA_PASSWORD="${GRAFANA_PASSWORD}"
EOF

        chmod 600 "$CREDS_FILE"
        echo -e "${GREEN}✓ Generated credentials${NC}"
    fi

    echo -e "${YELLOW}InfluxDB Token: ${INFLUXDB_TOKEN:0:15}...${NC}"
    echo -e "${YELLOW}Grafana Password: ${GRAFANA_PASSWORD:0:15}...${NC}"
    echo ""
}

##################################################################################################################################
# Generate self-signed certificates
##################################################################################################################################
generate_certificates() {
    mkdir -p "$CERT_DIR"

    local cert_file="${CERT_DIR}/${DOMAIN}.crt"
    local key_file="${CERT_DIR}/${DOMAIN}.key"

    if [ ! -f "$cert_file" ] || [ ! -f "$key_file" ] || [ "$REGENERATE_CREDS" = true ]; then
        echo -e "${CYAN}Generating self-signed certificates...${NC}"

        openssl req -x509 -newkey rsa:4096 \
            -keyout "$key_file" \
            -out "$cert_file" \
            -days 365 -nodes \
            -subj "/C=NL/ST=Gelderland/L=Apeldoorn/O=Development/CN=*.${DOMAIN}" \
            -addext "subjectAltName=DNS:*.${DOMAIN},DNS:${DOMAIN},DNS:tig-grafana.${DOMAIN},DNS:tig-explorer.${DOMAIN}" \
            2>/dev/null

        chmod 644 "$cert_file"
        chmod 600 "$key_file"

        echo -e "${GREEN}✓ Generated certificates${NC}"
    else
        echo -e "${GREEN}✓ Using existing certificates${NC}"
    fi

    # Base64 encode for K8s secret
    CERT_BASE64=$(base64 -w 0 "$cert_file" 2>/dev/null || base64 "$cert_file")
    KEY_BASE64=$(base64 -w 0 "$key_file" 2>/dev/null || base64 "$key_file")

    echo ""
}

##################################################################################################################################
# Update manifest with credentials and certificates
##################################################################################################################################
update_manifest() {
    echo -e "${CYAN}Creating deployment manifest...${NC}"

    local TEMP_MANIFEST="${SCRIPT_DIR}/tig-stack-manifests-ready.yaml"

    cp "$MANIFEST_FILE" "$TEMP_MANIFEST"

    # Use different delimiter for sed since tokens contain /
    sed -i.bak \
        -e "s|CHANGE_THIS_TO_NAMESPACE|${NAMESPACE}|g" \
        -e "s|CHANGE_THIS_TO_DOMAIN|${DOMAIN}|g" \
        -e "s|apiv3_CHANGE_THIS_TO_SECURE_GENERATED_TOKEN|${INFLUXDB_TOKEN}|g" \
        -e "s|CHANGE_THIS_TO_SECURE_PASSWORD|${GRAFANA_PASSWORD}|g" \
        -e "s|apiv3_CHANGE_THIS|${INFLUXDB_TOKEN}|g" \
        -e "s|\$INFLUXDB_TOKEN|${INFLUXDB_TOKEN}|g" \
        -e "s|CERT_BASE64_PLACEHOLDER|${CERT_BASE64}|g" \
        -e "s|KEY_BASE64_PLACEHOLDER|${KEY_BASE64}|g" \
        "$TEMP_MANIFEST"

    rm -f "${TEMP_MANIFEST}.bak"

    echo -e "${GREEN}✓ Manifest ready: ${TEMP_MANIFEST}${NC}"
    echo ""

    MANIFEST_FILE="$TEMP_MANIFEST"
}

##################################################################################################################################
# Show deployment plan
##################################################################################################################################
show_plan() {
    echo -e "${CYAN}Deployment Plan:${NC}"
    echo ""
    echo -e "  Namespace: ${NAMESPACE}"
    echo -e "  Domain: ${DOMAIN}"
    echo -e "  Storage: nfs-client"
    echo -e "  Ingress: nginx"
    echo ""
    echo -e "${CYAN}Resources:${NC}"
    echo "  • 1 Namespace"
    echo "  • 3 Secrets (credentials, TLS certificate, Grafana Token)"
    echo "  • 7 ConfigMaps (configs, scripts)"
    echo "  • 3 PVCs (Grafana, InfluxDB, Explorer - 65Gi total)"
    echo "  • 1 StatefulSet (InfluxDB)"
    echo "  • 3 Deployments (Grafana, Explorer, Telegraf)"
    echo "  • 3 Services"
    echo "  • 1 Job (initialization)"
    echo "  • 2 Ingresses (HTTPS via nginx)"
    echo "  • RBAC for Telegraf"
    echo ""
    echo -e "${CYAN}Endpoints:${NC}"
    echo "  • https://tig-grafana.${DOMAIN}"
    echo "  • https://tig-explorer.${DOMAIN}"
    echo ""
}

##################################################################################################################################
# Deploy to K3s
##################################################################################################################################
deploy() {
    if [ "$DRY_RUN" = true ]; then
        echo -e "${YELLOW}DRY RUN - Would execute:${NC}"
        echo "  kubectl apply -f $MANIFEST_FILE"
        echo ""
        kubectl apply -f "$MANIFEST_FILE" --dry-run=client
        return 0
    fi

    echo -e "${CYAN}Deploying to K3s...${NC}"

    if kubectl apply -f "$MANIFEST_FILE"; then
        echo -e "${GREEN}✓ Applied manifest${NC}"
    else
        echo -e "${RED}Error: Deployment failed${NC}"
        exit 1
    fi

    echo ""
}

##################################################################################################################################
# Wait for resources
##################################################################################################################################
wait_for_ready() {
    echo -e "${CYAN}Waiting for resources...${NC}"
    echo ""

    echo -e "Waiting for namespace..."
    kubectl wait --for=jsonpath='{.status.phase}'=Active namespace/$NAMESPACE --timeout=30s

    echo -e "Waiting for InfluxDB (may take 2-3 minutes)..."
    kubectl wait --for=condition=ready pod/tig-influxdb-0 -n $NAMESPACE --timeout=300s || {
        echo -e "${YELLOW}InfluxDB slow to start, check logs if needed${NC}"
    }

    echo -e "Waiting for Grafana..."
    kubectl wait --for=condition=available deployment/tig-grafana -n $NAMESPACE --timeout=180s

    echo -e "Waiting for Explorer..."
    kubectl wait --for=condition=available deployment/tig-explorer -n $NAMESPACE --timeout=180s

    echo -e "Waiting for Telegraf..."
    kubectl wait --for=condition=available deployment/tig-telegraf -n $NAMESPACE --timeout=180s

    echo -e "Checking initialization job..."
    if kubectl wait --for=condition=complete job/tig-init -n $NAMESPACE --timeout=120s 2>/dev/null; then
        echo -e "${GREEN}✓ Initialization complete${NC}"
    else
        echo -e "${YELLOW}⚠ Init job may still be running${NC}"
    fi

    echo ""
}

##################################################################################################################################
# Create Grafana Service Account Token
##################################################################################################################################
create_grafana_token() {
    echo -e "${CYAN}Creating Grafana Service Account Token...${NC}"

    # Wait a bit for Grafana to settle after init job
    sleep 5

    # Get ingress host
    local GRAFANA_URL="https://tig-grafana.${DOMAIN}"

    # Check if we can reach Grafana
    if ! curl -sk "${GRAFANA_URL}/api/health" >/dev/null 2>&1; then
        echo -e "${YELLOW}⚠ Cannot reach Grafana at ${GRAFANA_URL}${NC}"
        echo -e "${YELLOW}  Token creation will be skipped - run retrieve-grafana-token.sh later${NC}"
        return 1
    fi

    # Get Service Account ID
    echo -e "  Finding Service Account..."
    SA_RESPONSE=$(curl -sk -u "admin:${GRAFANA_PASSWORD}" \
        "${GRAFANA_URL}/api/serviceaccounts/search?query=tig-grafana-sa" 2>/dev/null)

    SA_ID=$(echo "$SA_RESPONSE" | grep -o '"id":[0-9]*' | head -1 | cut -d: -f2)

    if [ -z "$SA_ID" ]; then
        echo -e "${YELLOW}⚠ Service Account not found yet (init job may still be running)${NC}"
        echo -e "${YELLOW}  Run retrieve-grafana-token.sh later to create token${NC}"
        return 1
    fi

    echo -e "${GREEN}  ✓ Found Service Account ID: ${SA_ID}${NC}"

    # Create token
    echo -e "  Creating token..."
    TOKEN_NAME="tig-grafana-sa-token-$(date +%Y%m%d-%H%M%S)"

    TOKEN_RESPONSE=$(curl -sk -u "admin:${GRAFANA_PASSWORD}" \
        -X POST \
        -H "Content-Type: application/json" \
        -d "{\"name\":\"${TOKEN_NAME}\"}" \
        "${GRAFANA_URL}/api/serviceaccounts/${SA_ID}/tokens" 2>/dev/null)

    GRAFANA_TOKEN=$(echo "$TOKEN_RESPONSE" | grep -o '"key":"[^"]*"' | cut -d'"' -f4)

    if [ -z "$GRAFANA_TOKEN" ]; then
        echo -e "${YELLOW}⚠ Failed to create token${NC}"
        echo -e "${YELLOW}  Response: $TOKEN_RESPONSE${NC}"
        return 1
    fi

    echo -e "${GREEN}  ✓ Token created: ${TOKEN_NAME}${NC}"

    # Save to credentials file
    echo "" >> "$CREDS_FILE"
    echo "# Grafana Service Account Token (created $(date))" >> "$CREDS_FILE"
    echo "GRAFANA_SA_TOKEN=\"${GRAFANA_TOKEN}\"" >> "$CREDS_FILE"

    echo -e "${GREEN}  ✓ Token saved to ${CREDS_FILE}${NC}"

    # Create K8s secret
    echo -e "  Creating Kubernetes secret..."
    kubectl create secret generic grafana-sa-token \
        --from-literal=token="${GRAFANA_TOKEN}" \
        --from-literal=service-account-id="${SA_ID}" \
        --from-literal=service-account-name="tig-grafana-sa" \
        --from-literal=token-name="${TOKEN_NAME}" \
        --from-literal=created="$(date -Iseconds)" \
        -n $NAMESPACE \
        --dry-run=client -o yaml | kubectl apply -f - >/dev/null 2>&1

    echo -e "${GREEN}  ✓ Token saved to K8s secret: grafana-sa-token${NC}"
    echo -e "${YELLOW}  Token (first 15 chars): ${GRAFANA_TOKEN:0:15}...${NC}"
    echo ""

    return 0
}

##################################################################################################################################
# Show access info
##################################################################################################################################
show_access() {
    echo -e "${GREEN}============================================${NC}"
    echo -e "${GREEN}   Deployment Complete!                   ${NC}"
    echo -e "${GREEN}============================================${NC}"
    echo ""

    # Get MetalLB IP if available
    GRAFANA_IP=$(kubectl get ingress -n $NAMESPACE tig-grafana -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")

    if [ -n "$GRAFANA_IP" ]; then
        echo -e "${CYAN}LoadBalancer IP: ${GRAFANA_IP}${NC}"
        echo ""
    fi

    echo -e "${CYAN}Access URLs:${NC}"
    echo -e "  Grafana:  https://tig-grafana.${DOMAIN}"
    echo -e "  Explorer: https://tig-explorer.${DOMAIN}"
    echo ""
    echo -e "${CYAN}Grafana Login:${NC}"
    echo -e "  Username: admin"
    echo -e "  Password: ${GRAFANA_PASSWORD}"
    echo ""

    # Show Grafana token info
    if kubectl get secret -n $NAMESPACE grafana-sa-token &>/dev/null; then
        echo -e "${GREEN}✓ Grafana Service Account Token created and saved${NC}"
        echo -e "  Retrieve with: kubectl get secret -n ${NAMESPACE} grafana-sa-token -o jsonpath='{.data.token}' | base64 -d"
        echo ""
    fi
    # Show Grafana Admin Passowrd info
    if kubectl get secret -n $NAMESPACE tig-credentials &>/dev/null; then
        echo -e "${GREEN}✓ Grafana Admin Password created and saved${NC}"
        echo -e "  Retrieve with: kubectl get secret -n ${NAMESPACE} tig-credentials -o jsonpath='{.data.grafana-admin-password}' | base64 -d"
        echo ""
    fi

    echo -e "${CYAN}Useful Commands:${NC}"
    echo "  # View all resources"
    echo "  kubectl get all -n ${NAMESPACE}"
    echo ""
    echo "  # Check logs"
    echo "  kubectl logs -n ${NAMESPACE} tig-influxdb-0"
    echo "  kubectl logs -n ${NAMESPACE} -l app=tig-grafana"
    echo "  kubectl logs -n ${NAMESPACE} job/tig-init"
    echo ""
    echo -e "${YELLOW}Credentials: ${CREDS_FILE}${NC}"
    echo -e "${YELLOW}Certificates: ${CERT_DIR}/${DOMAIN}.{crt,key}${NC}"
    echo ""
}

##################################################################################################################################
# Quick status check
##################################################################################################################################
show_status() {
    echo -e "${CYAN}Current Status:${NC}"
    echo ""
    kubectl get pods -n $NAMESPACE
    echo ""
    kubectl get pvc -n $NAMESPACE
    echo ""
    kubectl get ingress -n $NAMESPACE
    echo ""
}

##################################################################################################################################
# Main
##################################################################################################################################
main() {
    check_prerequisites
    generate_credentials
    generate_certificates
    update_manifest
    show_plan

    if [ "$DRY_RUN" = false ]; then
        read -p "Deploy now? (yes/no): " -r
        echo
        if [[ ! $REPLY =~ ^[Yy]es$ ]]; then
            echo -e "${YELLOW}Cancelled${NC}"
            exit 0
        fi
    fi

    deploy

    if [ "$DRY_RUN" = false ]; then
        wait_for_ready
	    create_grafana_token
        show_status
        show_access
    fi
}

main
#!/bin/bash

set -e

check_commands()
{
    for cmd in "$@"
    do
        check_command "$cmd"
    done
}

check_command()
{
    command -v "$1" > /dev/null && return 0

    printf "please install '%s' before running this script\n" "$1"
    exit 1
}

check_commands crc jq yq oc kubectl kustomize git make timeout base64

# Configure and Run CRC
crc config set enable-cluster-monitoring true
crc start --memory 20480 --cpus 6

# oc login
CRC_CRED=$(crc console --credentials -o json)
CRC_URL=$(echo "$CRC_CRED" | jq -r '.clusterConfig.url')
CRC_KUBEADMIN_PASSWORD=$(echo "$CRC_CRED" | jq -r '.clusterConfig.adminCredentials.password')
oc login "$CRC_URL" -u kubeadmin -p "$CRC_KUBEADMIN_PASSWORD"

# Wait for openshift-marketplace/community-operator pods to become ready
timeout --foreground 20m bash <<- "EOF" || exit 1
    while ! (kubectl wait pods --for=condition=ready -n openshift-marketplace -l olm.catalogSource=community-operators --timeout 1m); do
        printf "waiting for community-operators pods in openshift-marketplace to become available\n"
        kubectl get pods -n openshift-marketplace -l olm.catalogSource=community-operators
    done
EOF

# Install keycloak
export KEYCLOAK_SECRET=$(openssl rand -base64 32)
timeout --foreground 20m bash <<- "EOF" || exit 1
    while ! (envsubst '$KEYCLOAK_SECRET' < <( kustomize build components/dev-sso/ ) | kubectl apply -f -); do
        printf "\nkubectl get subscriptions -n dev-sso dev-sso\n"
        kubectl get subscriptions -n dev-sso dev-sso
        kubectl get subscriptions.operators.coreos.com -n dev-sso dev-sso -o yaml | yq -e '.status.conditions'
        printf "\n"

        printf "Retrying in 20 seconds...\n"
        sleep 20
    done
EOF

while ! kubectl get statefulset -n dev-sso keycloak &> /dev/null ; do
    sleep 10
done

kubectl rollout status statefulset -n dev-sso keycloak --timeout 20m

# Configure cluster OAuth authentication for keycloak
oc apply -f - << EOF
apiVersion: v1
kind: Secret
metadata:
  name: openid-client-secret-sandbox
  namespace: openshift-config
stringData:
  clientSecret: $KEYCLOAK_SECRET
type: Opaque
EOF

# Certificate used by keycloak is self-signed, we need to import and grant for it
kubectl get secrets -n openshift-ingress-operator router-ca -o jsonpath='{.data.tls\.crt}' | base64 -d > /tmp/ca.crt
oc create configmap ca-config-map --from-file="ca.crt=/tmp/ca.crt" -n openshift-config

# Patch
oc patch oauths.config.openshift.io/cluster --type=merge --patch-file=/dev/stdin << EOF
spec:
  identityProviders:
  - htpasswd:
      fileData:
        name: htpass-secret
    mappingMethod: claim
    name: developer
    type: HTPasswd
  - mappingMethod: lookup
    name: rhd
    openID:
      ca:
        name: ca-config-map
      claims:
        preferredUsername:
        - preferred_username
      clientID: sandbox
      clientSecret:
        name: openid-client-secret-sandbox
      issuer: https://keycloak-dev-sso.apps-crc.testing/auth/realms/sandbox-dev
    type: OpenID
EOF

# This patch disables `oc login -u kubeadmin ...` authentication method, but won't present the form 
# for selecting login provider after registration on registration-service
#
# oc patch oauths.config.openshift.io/cluster --type=merge --patch-file=/dev/stdin << EOF
# spec:
#   identityProviders:
#   - mappingMethod: lookup
#     name: rhd
#     openID:
#       ca:
#         name: ca-config-map
#       claims:
#         preferredUsername:
#         - preferred_username
#       clientID: sandbox
#       clientSecret:
#         name: openid-client-secret-sandbox
#       issuer: https://keycloak-dev-sso.apps-crc.testing/auth/realms/sandbox-dev
#     type: OpenID
# EOF

### Remove the comment here if you are following the procedure
### to create a Keycloak enabled cluster CRC Bundle
# exit 0

# Install toolchain operator
TOOLCHAIN_E2E_TEMP_DIR="/tmp/toolchain-e2e"
rm -rf "${TOOLCHAIN_E2E_TEMP_DIR}" 2>/dev/null || true
git clone --depth=1 https://github.com/codeready-toolchain/toolchain-e2e.git "${TOOLCHAIN_E2E_TEMP_DIR}"
make -C "${TOOLCHAIN_E2E_TEMP_DIR}" dev-deploy-latest SHOW_CLEAN_COMMAND="make -C ${TOOLCHAIN_E2E_TEMP_DIR} clean-dev-resources"

## Configure toolchain to use the internal keycloak
BASE_URL=$(oc get ingresses.config.openshift.io/cluster -o jsonpath='{.spec.domain}')
RHSSO_URL="https://keycloak-dev-sso.$BASE_URL"

oc patch ToolchainConfig/config -n toolchain-host-operator --type=merge --patch-file=/dev/stdin << EOF
spec:
  host:
    registrationService:
      auth:
        authClientConfigRaw: '{
                  "realm": "sandbox-dev",
                  "auth-server-url": "$RHSSO_URL/auth",
                  "ssl-required": "none",
                  "resource": "sandbox-public",
                  "clientId": "sandbox-public",
                  "public-client": true,
                  "confidential-port": 0
                }'
        authClientLibraryURL: $RHSSO_URL/auth/js/keycloak.js
        authClientPublicKeysURL: $RHSSO_URL/auth/realms/sandbox-dev/protocol/openid-connect/certs
EOF

# Restart the registration-service to ensure the new configuration is used
kubectl delete pods -n toolchain-host-operator --selector=name=registration-service

KEYCLOAK_ADMIN_PASSWORD=$(kubectl get secrets -n dev-sso credential-sandbox-dev -o jsonpath='{.data.ADMIN_PASSWORD}' | base64 -d)
printf "to login into keycloak use user 'admin' and password '%s' at '%s/auth'\n" "$KEYCLOAK_ADMIN_PASSWORD" "$RHSSO_URL"
printf "use user 'user1@user.us' with password 'user1' to login at 'https://registration-service-toolchain-host-operator.apps-crc.testing'\n"

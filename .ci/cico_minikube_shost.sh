#!/usr/bin/env bash
#
# Copyright (c) 2020 Red Hat, Inc.
# This program and the accompanying materials are made
# available under the terms of the Eclipse Public License 2.0
# which is available at https://www.eclipse.org/legal/epl-2.0/
#
# SPDX-License-Identifier: EPL-2.0
#
# Contributors:
#   Red Hat, Inc. - initial API and implementation

# exit immediately when a command fails
set -e
# only exit with zero if all commands of the pipeline exit successfully
set -o pipefail
# error on unset variables
set -u
# print each command before executing it
set -x

#Stop execution on any error
trap "catchFinish" EXIT SIGINT

# Define global environments
function init() {
  export SCRIPT=$(readlink -f "$0")
  export SCRIPT_DIR=$(dirname "$SCRIPT")
  export OPERATOR_REPO=$(dirname "$SCRIPT_DIR");

  export RAM_MEMORY=8192
  export NAMESPACE="che"
  export PLATFORM="kubernetes"

  # Directory where che artifacts will be stored and uploded to GH actions artifacts
  export ARTIFACTS_DIR="/tmp/artifacts-che"

  # Set operator root directory
  export OPERATOR_IMAGE="che-operator:tests"
}

# Catch_Finish is executed after finish script.
catchFinish() {
  result=$?

  if [ "$result" != "0" ]; then
    echo "[ERROR] Please check the github actions artifacts"
    collectCheLogWithChectl
    exit 1
  fi

  echo "[INFO] Job finished Successfully.Please check github actions artifacts"
  collectCheLogWithChectl

  exit $result
}

# Utility to get che events and pod logs from openshift cluster
function collectCheLogWithChectl() {
  mkdir -p ${ARTIFACTS_DIR}
  chectl server:logs --directory=${ARTIFACTS_DIR}
}

# Get Token from single host mode deployment
function getSingleHostToken() {
    export GATEWAY_HOSTNAME=$(minikube ip).nip.io
    export TOKEN_ENDPOINT="https://${GATEWAY_HOSTNAME}/auth/realms/che/protocol/openid-connect/token"
    export CHE_ACCESS_TOKEN=$(curl --data "grant_type=password&client_id=che-public&username=admin&password=admin" -k ${TOKEN_ENDPOINT} | jq -r .access_token)
}

# Utility to wait for a workspace to be started after workspace:create.
function waitSingleHostWorkspaceStart() {
  set +e
  export x=0
  while [ $x -le 180 ]
  do
    getSingleHostToken

    # List Workspaces and get the status
    echo "[INFO] Getting workspace status:"
    chectl workspace:list
    workspaceList=$(chectl workspace:list --chenamespace=${NAMESPACE})
    workspaceStatus=$(echo "$workspaceList" | grep RUNNING | awk '{ print $4} ')

    if [ "${workspaceStatus:-NOT_RUNNING}" == "RUNNING" ]
    then
      echo "[INFO] Workspace started successfully"
      break
    fi
    sleep 10
    x=$(( x+1 ))
  done

  if [ $x -gt 180 ]
  then
    echo "[ERROR] Workspace didn't start after 3 minutes."
    exit 1
  fi
}

# Build latest operator image
function buildCheOperatorImage() {
    docker build -t "${OPERATOR_IMAGE}" -f Dockerfile . && docker save "${OPERATOR_IMAGE}" > operator.tar
    eval $(minikube docker-env) && docker load -i operator.tar && rm operator.tar
}

# Deploy Eclipse Che in single host mode(gateway exposure type)
function runSHostGatewayExposure() {
    # Patch file to pass to chectl
    cat >/tmp/che-cr-patch.yaml <<EOL
spec:
  server:
    serverExposureStrategy: 'single-host'
  auth:
    updateAdminPassword: false
    openShiftoAuth: false
  k8s:
    singleHostExposureType: 'gateway'
EOL
    echo "======= Che cr patch ======="
    cat /tmp/che-cr-patch.yaml

    # Use custom changes, don't pull image from quay.io
    oc create namespace che
    cat ${OPERATOR_REPO}/deploy/operator.yaml | \
    sed 's|imagePullPolicy: Always|imagePullPolicy: IfNotPresent|' | \
    sed 's|quay.io/eclipse/che-operator:nightly|'${OPERATOR_IMAGE}'|' | \
    oc apply -n ${NAMESPACE} -f -

    # Start to deploy Che
    chectl server:start --platform=minikube --skip-kubernetes-health-check --installer=operator \
        --chenamespace=${NAMESPACE} --che-operator-image=${OPERATOR_IMAGE} --che-operator-cr-patch-yaml=/tmp/che-cr-patch.yaml

    # Create and start a workspace
    getSingleHostToken # Function from ./util/ci_common.sh
    chectl workspace:create --start --devfile=$OPERATOR_REPO/.ci/util/devfile-test.yaml

    # Wait for workspace to be up
    waitSingleHostWorkspaceStart

    chectl server:delete --chenamespace=${NAMESPACE} --skip-deletion-check
}

# Deploy Eclipse Che in single host mode(native exposure type)
function runSHostNativeExposure() {
    # Patch file to pass to chectl
    cat >/tmp/che-cr-patch.yaml <<EOL
spec:
  server:
    serverExposureStrategy: 'single-host'
  auth:
    updateAdminPassword: false
    openShiftoAuth: false
EOL
    echo "======= Che cr patch ======="
    cat /tmp/che-cr-patch.yaml

    # Use custom changes, don't pull image from quay.io
    checkNamespace
    cat ${OPERATOR_REPO}/deploy/operator.yaml | \
    sed 's|imagePullPolicy: Always|imagePullPolicy: IfNotPresent|' | \
    sed 's|quay.io/eclipse/che-operator:nightly|'${OPERATOR_IMAGE}'|' | \
    oc apply -n ${NAMESPACE} -f -

    # Start to deploy Che
    chectl server:start --platform=minikube --skip-kubernetes-health-check --installer=operator \
        --chenamespace=${NAMESPACE} --che-operator-image=${OPERATOR_IMAGE} --che-operator-cr-patch-yaml=/tmp/che-cr-patch.yaml

    # Get the token from .ci/util/common.sh
    getCheAcessToken
    chectl workspace:create --start --devfile=$OPERATOR_REPO/.ci/util/devfile-test.yaml

    # Wait for workspace to be up for native deployment from .ci/util/common.sh
    waitWorkspaceStart

    chectl server:delete --chenamespace=${NAMESPACE} --skip-deletion-check
}

init
source "${OPERATOR_REPO}"/.ci/util/ci_common.sh
echo "[INFO] Start to Building Che Operator Image"
buildCheOperatorImage

echo "[INFO] Start to run single host with gateway exposure mode"
runSHostGatewayExposure

echo "[INFO] Start to run single host in native mode"
runSHostNativeExposure

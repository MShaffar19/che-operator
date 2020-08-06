#!/bin/bash
#
# Copyright (c) 2012-2020 Red Hat, Inc.
# This program and the accompanying materials are made
# available under the terms of the Eclipse Public License 2.0
# which is available at https://www.eclipse.org/legal/epl-2.0/
#
# SPDX-License-Identifier: EPL-2.0
#

set -e

# Detect the base directory where che-operator is cloned
SCRIPT=$(readlink -f "$0")
export SCRIPT

OPERATOR_REPO=$(dirname "$(dirname "$SCRIPT")");
export OPERATOR_REPO

# ENV used by Openshift CI
ARTIFACTS_DIR="/tmp/artifacts"
export ARTIFACTS_DIR

CATALOG_SOURCE_IMAGE="che_catalog"
export CATALOG_SOURCE_IMAGE

# Choose if install Eclipse Che using an operatorsource or Custom Catalog Source
INSTALLATION_TYPE="catalog"
export INSTALLATION_TYPE

# Execute olm nightly files in openshift
PLATFORM="openshift"
export PLATFORM

# Test nightly olm files
CHANNEL="nightly"
export CHANNEL

# Test nightly olm files
NAMESPACE="che-operator"
export NAMESPACE

# run function run the tests in ci of custom catalog source.
function run() {
    # Execute test catalog source script
    source "${OPERATOR_REPO}"/olm/testCatalogSource.sh ${PLATFORM} ${CHANNEL} ${NAMESPACE} ${INSTALLATION_TYPE} ${CATALOG_SOURCE_IMAGE}

    source "${OPERATOR_REPO}"/.ci/util/ci_common.sh
    oc project ${NAMESPACE}
    
    # Create and start a workspace
    getCheAcessToken
    chectl workspace:create --start --devfile=$OPERATOR_REPO/.ci/util/devfile-test.yaml 
    
    getCheAcessToken
    chectl workspace:list
    waitWorkspaceStart
}

run

# grab che-operator namespace events after running olm nightly tests
oc get events -n ${NAMESPACE} | tee ${ARTIFACTS_DIR}/che-operator-events.log
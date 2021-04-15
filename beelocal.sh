#!/usr/bin/env bash

set -eo pipefail
# set -x
#/
#/ Usage:
#/ ./beelocal.sh
#/
#/ Description:
#/ Spinup local k8s infra with geth and bee up and running
#/
#/ Example:
#/ REPLICA=5 ACTION=install OPTS="clef" ./beelocal.sh
#/
#/ ACTION=install OPTS="clef skip-local" ./beelocal.sh
#/
#/ Actions: build check destroy geth install prepare uninstall start stop
#/
#/ Options: clef postage skip-local skip-peer

# parse file and print usage text
usage() { grep '^#/' "$0" | cut -c4- ; exit 0 ; }
expr "$*" : ".*-h" > /dev/null && usage
expr "$*" : ".*--help" > /dev/null && usage

declare -x BRANCH=${BRANCH:-main}

declare -x DOCKER_BUILDKIT="1"
declare -x ACTION=${ACTION:-run}
declare -x REPLICA=${REPLICA:-3}
declare -x CHART=${CHART:-ethersphere/bee}
declare -x IMAGE=${IMAGE:-k3d-registry.localhost:5000/ethersphere/bee}
declare -x IMAGE_TAG=${IMAGE_TAG:-latest}

check() {
    if ! grep -qE "docker|admin" <<< "$(id "$(whoami)")"; then
        if (( EUID != 0 )); then
            echo "$(whoami) not member of docker group..."
            exit 1
        fi
    fi
    if ! command -v jq &> /dev/null; then
        echo "jq is missing..."
        exit 1
    elif ! command -v curl &> /dev/null; then
        echo "curl is missing..."
        exit 1
    elif ! command -v kubectl &> /dev/null; then
        echo "kubectl is missing..."
        exit 1
    elif ! command -v docker &> /dev/null; then
        echo "docker is missing..."
        exit 1
    fi

    if ! command -v helm &> /dev/null; then
        echo "helm is missing..."
        echo "installing helm..."
        curl -sSL https://raw.githubusercontent.com/helm/helm/master/scripts/get-helm-3 | bash
    fi

    if ! command -v k3d &> /dev/null; then
        echo "k3d is missing..."
        echo "installing k3d..."
        curl -sSL https://raw.githubusercontent.com/rancher/k3d/main/install.sh | TAG=v4.4.1 bash
    fi
    if [[ -z $LOCAL_CONFIG ]]; then
        BEE_TEMP=$(mktemp -d -t bee-XXX)
        trap 'rm -rf ${BEE_TEMP}' EXIT
        curl -sSL https://raw.githubusercontent.com/ethersphere/beelocal/"${BRANCH}"/config/k3d.yaml -o "${BEE_TEMP}"/k3d.yaml
        curl -sSL https://raw.githubusercontent.com/ethersphere/beelocal/"${BRANCH}"/config/bee.yaml -o "${BEE_TEMP}"/bee.yaml
        curl -sSL https://raw.githubusercontent.com/ethersphere/beelocal/"${BRANCH}"/config/geth-swap.yaml -o "${BEE_TEMP}"/geth-swap.yaml
        BEE_CONFIG="${BEE_TEMP}"
    fi
}

prepare() {
    echo "starting k3d cluster..."
    k3d registry create registry.localhost -p 5000 || true
    k3d cluster create --config "${BEE_CONFIG}"/k3d.yaml || true
    echo "waiting for the cluster..."
    until k3d kubeconfig get bee; do sleep 1; done
    kubectl create ns local || true
    if [[ $(helm repo list) != *ethersphere* ]]; then
        helm repo add ethersphere https://ethersphere.github.io/helm
    fi
    helm repo update

    echo "waiting for the kube-system..."
    until kubectl get svc traefik -n kube-system &> /dev/null; do sleep 1; done
    geth
    echo "cluster running..."
}

build() {
    cd "${GOPATH}"/src/github.com/ethersphere/bee
    make lint vet test-race
    docker build -t k3d-registry.localhost:5000/ethersphere/bee:"${IMAGE_TAG}" . --cache-from=k3d-registry.localhost:5000/ethersphere/bee:"${IMAGE_TAG}" --build-arg BUILDKIT_INLINE_CACHE=1
    docker push k3d-registry.localhost:5000/ethersphere/bee:"${IMAGE_TAG}"
    cd -
}

install() {
    geth
    LAST_BEE=$((REPLICA-1))
    if helm get values bee -n local -o json &> /dev/null; then # if release exists do rolling upgrade
        BEES=$(seq $LAST_BEE -1 0)
    else
        BEES=$(seq 0 1 $LAST_BEE)
    fi
    helm upgrade --install bee -f "${BEE_CONFIG}"/bee.yaml "${CHART}" -n local --set image.repository="${IMAGE}" --set image.tag="${IMAGE_TAG}" --set replicaCount="${REPLICA}" ${CLEF} ${POSTAGE}
    for i in ${BEES}; do
        echo "waiting for the bee-${i}..."
        until [[ "$(curl -s bee-"${i}"-debug.localhost/readiness | jq -r .status 2>/dev/null)" == "ok" ]]; do sleep 1; done
    done
    if [[ -z $SKIP_PEER ]]; then
        for i in ${BEES}; do
            echo "waiting for full peer connectivity for bee-${i}..."
            until [[ "$(curl -s bee-"${i}"-debug.localhost/peers | jq -r '.peers | length' 2> /dev/null)" -eq ${LAST_BEE} ]]; do sleep 1; done
        done
    fi
}

uninstall() {
    echo "uninstalling bee and geth releases..."
    helm uninstall bee -n local
    helm uninstall geth-swap -n local
    echo "uninstalled bee and geth releases..."
}

geth() {
    if helm get values geth-swap -n local -o json &> /dev/null; then # if release exists doesn't install geth
        echo "geth already installed..."
    else
        echo "installing geth..."
        helm install geth-swap ethersphere/geth-swap -n local -f "${BEE_CONFIG}"/geth-swap.yaml
        echo "waiting for the geth init..."
        until [[ $(kubectl get pod -n local -l job-name=geth-swap-setupcontracts -o json | jq -r .items[0].status.containerStatuses[0].state.terminated.reason 2>/dev/null) == "Completed" ]]; do sleep 1; done
        echo "installed geth..."
    fi
}

stop() {
    echo "stoping k3d cluster..."
    k3d cluster stop bee 
    docker stop k3d-registry.localhost
    echo "stopped k3d cluster..."
}

start() {
    echo "starting k3d cluster..."
    docker start k3d-registry.localhost
    k3d cluster start bee
    echo "started k3d cluster..."
}

destroy() {
    echo "destroying k3d cluster..."
    k3d cluster delete bee || true
    k3d registry delete k3d-registry.localhost || true
    k3d registry delete k3d-bee-registry || true
    echo "detroyed k3d cluster..."
}

ALLOW_OPTS=(clef postage skip-local skip-peer)
for OPT in $OPTS; do
    if [[ " ${ALLOW_OPTS[*]} " == *"$OPT"* ]]; then
        if [[ $OPT == "clef" ]]; then
            CLEF="--set beeConfig.clef_signer_enable=true --set clefSettings.enabled=true"
        fi
        if [[ $OPT == "postage" ]]; then
            POSTAGE="--set beeConfig.postage_stamp_address=0x538e6de1d876bbcd5667085257bc92f7c808a0f3 --set beeConfig.price_oracle_address=0xfc28330f1ece0ef2371b724e0d19c1ee60b728b2"
        fi
        if [[ $OPT == "skip-local" ]]; then
            IMAGE="ethersphere/bee"
            SKIP_LOCAL="true"
        fi
        if [[ $OPT == "skip-peer" ]]; then
            SKIP_PEER="true"
        fi
    else
        echo "$OPT is unknown option..."
        exit 1
    fi
done

ACTIONS=(build check destroy geth install prepare uninstall start stop run)
if [[ " ${ACTIONS[*]} " == *"$ACTION"* ]]; then

    if [[ $ACTION == "run" ]]; then
        check
        if [[ $(k3d cluster list bee -o json 2>/dev/null| jq -r .[0].serversRunning) == "0" ]]; then
            start
        elif ! k3d cluster list bee --no-headers &> /dev/null; then
            prepare
        fi
        if [[ -z $SKIP_LOCAL ]]; then
            build
        fi
        install
    else
        $ACTION
    fi
    exit 0
else
    echo "$ACTION is unknown action..."
    exit 1
fi

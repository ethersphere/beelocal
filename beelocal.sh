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

declare -x BEELOCAL_BRANCH=${BEELOCAL_BRANCH:-main}
declare -x K3S_VERSION=${K3S_VERSION:-v1.19.7+k3s1}

declare -x DOCKER_BUILDKIT="1"
declare -x ACTION=${ACTION:-run}
declare -x REPLICA=${REPLICA:-3}
declare -x CHART=${CHART:-ethersphere/bee}
declare -x IMAGE=${IMAGE:-k3d-registry.localhost:5000/ethersphere/bee}
declare -x IMAGE_TAG=${IMAGE_TAG:-latest}
declare -x NAMESPACE=${NAMESPACE:-local}
declare -x PAYMENT_THRESHOLD=${PAYMENT_THRESHOLD}
if [[ -n $PAYMENT_THRESHOLD ]]; then
    PAYMENT="--set beeConfig.payment_threshold=${PAYMENT_THRESHOLD} --set beeConfig.payment_tolerance=$((PAYMENT_THRESHOLD/10)) --set beeConfig.payment_early=$((PAYMENT_THRESHOLD/10))"
else
    PAYMENT=
fi

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

    if [[ -n $CI ]]; then
        if ! command -v k3s &> /dev/null; then
            echo "k3s is missing..."
            echo "installing k3s.."
            K3S_FOLDER=/tmp/k3s-"${K3S_VERSION}"
            if [[ ! -d "${K3S_FOLDER}" ]]; then
                mkdir -p "${K3S_FOLDER}"
                curl -sL https://get.k3s.io -o "${K3S_FOLDER}"/k3s_install.sh
                curl -sL https://github.com/k3s-io/k3s/releases/download/"${K3S_VERSION/+/%2B}"/k3s -o "${K3S_FOLDER}"/k3s
                curl -sL https://github.com/k3s-io/k3s/releases/download/"${K3S_VERSION/+/%2B}"/k3s-airgap-images-amd64.tar -o "${K3S_FOLDER}"/k3s-airgap-images-amd64.tar
            fi
            sudo mkdir -p /etc/rancher/k3s/
            sudo mkdir -p /var/lib/rancher/k3s/agent/images/
            sudo mkdir -p /var/lib/rancher/k3s/server/manifests/
            cp "${K3S_FOLDER}"/k3s_install.sh .
            sudo cp "${K3S_FOLDER}"/k3s /usr/local/bin/k3s
            sudo cp "${K3S_FOLDER}"/k3s-airgap-images-amd64.tar /var/lib/rancher/k3s/agent/images/
            sudo chmod +x k3s_install.sh /usr/local/bin/k3s
        fi
    else
        if ! command -v k3d &> /dev/null; then
            echo "k3d is missing..."
            echo "installing k3d..."
            curl -sSL https://raw.githubusercontent.com/rancher/k3d/main/install.sh | TAG=v4.4.1 bash
        fi
    fi
}

config() {
    if [[ -z $LOCAL_CONFIG ]]; then
        BEE_TEMP=$(mktemp -d -t bee-XXX)
        trap 'rm -rf ${BEE_TEMP}' EXIT
        curl -sSL https://raw.githubusercontent.com/ethersphere/beelocal/"${BEELOCAL_BRANCH}"/config/k3d.yaml -o "${BEE_TEMP}"/k3d.yaml
        curl -sSL https://raw.githubusercontent.com/ethersphere/beelocal/"${BEELOCAL_BRANCH}"/config/bee.yaml -o "${BEE_TEMP}"/bee.yaml
        curl -sSL https://raw.githubusercontent.com/ethersphere/beelocal/"${BEELOCAL_BRANCH}"/config/geth-swap.yaml -o "${BEE_TEMP}"/geth-swap.yaml
        if [[ -n $CI ]]; then
            curl -sSL https://raw.githubusercontent.com/ethersphere/beelocal/"${BEELOCAL_BRANCH}"/hack/coredns.yaml -o "${BEE_TEMP}"/coredns.yaml
            curl -sSL https://raw.githubusercontent.com/ethersphere/beelocal/"${BEELOCAL_BRANCH}"/hack/registries.yaml -o "${BEE_TEMP}"/registries.yaml
            curl -sSL https://raw.githubusercontent.com/ethersphere/beelocal/"${BEELOCAL_BRANCH}"/hack/traefik.yaml -o "${BEE_TEMP}"/traefik.yaml
            sudo cp "${BEE_TEMP}"/registries.yaml /etc/rancher/k3s/registries.yaml
            sudo cp "${BEE_TEMP}"/coredns.yaml /var/lib/rancher/k3s/server/manifests/coredns-custom.yaml
            sudo cp "${BEE_TEMP}"/traefik.yaml /var/lib/rancher/k3s/server/manifests/traefik-config.yaml
        fi
        BEE_CONFIG="${BEE_TEMP}"
    fi
}

prepare() {
    config
    if [[ -n $CI ]]; then
        echo "starting k3s cluster..."
        docker container run -d --name k3d-registry.localhost -v registry:/var/lib/registry --restart always -p 5000:5000 registry:2 || true
        INSTALL_K3S_SKIP_DOWNLOAD=true K3S_KUBECONFIG_MODE="644" INSTALL_K3S_EXEC="--disable=coredns" ./k3s_install.sh
        export KUBECONFIG=/etc/rancher/k3s/k3s.yaml  
        echo "waiting for the cluster..."  
    else
        echo "starting k3d cluster..."
        k3d registry create registry.localhost -p 5000 || true
        k3d cluster create --config "${BEE_CONFIG}"/k3d.yaml || true
        echo "waiting for the cluster..."
        until k3d kubeconfig get bee; do sleep 1; done
    fi
    kubectl create ns "${NAMESPACE}" || true
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
    if [[ -n $BEE_FOLDER ]]; then
        cd "${BEE_FOLDER}"
        BEE_CD=true
    elif [[ ! -f Makefile ]]; then
        cd "${GOPATH}"/src/github.com/ethersphere/bee
        BEE_CD=true
    fi
    if [[ -z $SKIP_VET ]]; then
        make lint vet test-race
    fi
    if [[ -n $CI ]]; then
        make binary
        mv dist/bee bee
        docker build -t k3d-registry.localhost:5000/ethersphere/bee:"${IMAGE_TAG}" -f Dockerfile.goreleaser . --cache-from=ghcr.io/ethersphere/bee --build-arg BUILDKIT_INLINE_CACHE=1
    else
        docker build -t k3d-registry.localhost:5000/ethersphere/bee:"${IMAGE_TAG}" . --cache-from=k3d-registry.localhost:5000/ethersphere/bee:"${IMAGE_TAG}" --build-arg BUILDKIT_INLINE_CACHE=1
    fi
    docker push k3d-registry.localhost:5000/ethersphere/bee:"${IMAGE_TAG}"
    if [[ -n $BEE_CD ]]; then
        cd -
    fi
}

install() {
    if [[ -z $BEE_CONFIG ]]; then
        config
    fi
    geth
    if [[ -z $SKIP_LOCAL ]]; then
        build
    fi
    LAST_BEE=$((REPLICA-1))
    if helm get values bee -n "${NAMESPACE}" -o json &> /dev/null; then # if release exists do rolling upgrade
        BEES=$(seq $LAST_BEE -1 0)
    else
        BEES=$(seq 0 1 $LAST_BEE)
    fi
    helm upgrade --install bee -f "${BEE_CONFIG}"/bee.yaml "${CHART}" -n "${NAMESPACE}" --set image.repository="${IMAGE}" --set image.tag="${IMAGE_TAG}" --set replicaCount="${REPLICA}" ${CLEF} ${POSTAGE} ${PAYMENT} ${SWAP} ${HELM_OPTS}
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
    helm uninstall bee -n "${NAMESPACE}"
    helm uninstall geth-swap -n "${NAMESPACE}"
    echo "uninstalled bee and geth releases..."
}

geth() {
    if helm get values geth-swap -n "${NAMESPACE}" -o json &> /dev/null; then # if release exists doesn't install geth
        echo "geth already installed..."
    else
        echo "installing geth..."
        helm install geth-swap ethersphere/geth-swap -n "${NAMESPACE}" -f "${BEE_CONFIG}"/geth-swap.yaml ${GETH_HELM_OPTS}
        echo "waiting for the geth init..."
        until [[ $(kubectl get pod -n "${NAMESPACE}" -l job-name=geth-swap-setupcontracts -o json | jq -r .items[0].status.containerStatuses[0].state.terminated.reason 2>/dev/null) == "Completed" ]]; do sleep 1; done
        echo "installed geth..."
    fi
}

stop() {
    if [[ -n $CI ]]; then
        echo "action not upported for CI"
        exit 1
    fi
    echo "stoping k3d cluster..."
    k3d cluster stop bee 
    docker stop k3d-registry.localhost
    echo "stopped k3d cluster..."
}

start() {
    if [[ -n $CI ]]; then
        echo "action not upported for CI"
        exit 1
    fi
    echo "starting k3d cluster..."
    docker start k3d-registry.localhost
    k3d cluster start bee
    echo "started k3d cluster..."
}

destroy() {
    if [[ -n $CI ]]; then
        echo "destroying k3s cluster..."
        docker rm -f registry.localhost || true
        /usr/local/bin/k3s-uninstall.sh || true
        echo "detroyed k3s cluster..."
    else
        echo "destroying k3d cluster..."
        k3d cluster delete bee || true
        k3d registry delete k3d-registry.localhost || true
        if docker inspect k3d-bee-registry &> /dev/null; then
            k3d registry delete k3d-bee-registry || true
        fi
        echo "detroyed k3d cluster..."
    fi
}

ALLOW_OPTS=(clef postage skip-local skip-peer skip-vet disable-swap ci)
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
        if [[ $OPT == "skip-vet" ]]; then
            SKIP_VET="true"
        fi
        if [[ $OPT == "disable-swap" ]]; then
            SWAP="--set beeConfig.swap_enable=false"
        fi
        if [[ $OPT == "ci" ]]; then
            CI="true"
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
        install
    else
        $ACTION
    fi
    exit 0
else
    echo "$ACTION is unknown action..."
    exit 1
fi

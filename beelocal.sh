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
#/ ACTION=install OPTS="clef" ./beelocal.sh
#/
#/ ACTION=install OPTS="clef skip-local" ./beelocal.sh
#/
#/ Actions: build check prepare destroy geth install k8s-local uninstall start stop
#/
#/ Options: skip-local skip-vet skip-push ci

# parse file and print usage text
usage() { grep '^#/' "$0" | cut -c4- ; exit 0 ; }
expr "$*" : ".*-h" > /dev/null && usage
expr "$*" : ".*--help" > /dev/null && usage

declare -x DOCKER_BUILDKIT="1"
declare -x BEELOCAL_BRANCH=${BEELOCAL_BRANCH:-main}
declare -x K3S_VERSION=${K3S_VERSION:-v1.31.10+k3s1}

declare -x K3S_FOLDER=${K3S_FOLDER:-"/tmp/k3s-${K3S_VERSION}"}

declare -x ACTION=${ACTION:-run}

declare -x IMAGE=${IMAGE:-k3d-registry.localhost:5000/ethersphere/bee}
declare -x IMAGE_TAG=${IMAGE_TAG:-latest}
declare -x SETUP_CONTRACT_IMAGE=${SETUP_CONTRACT_IMAGE:-ethersphere/bee-localchain}
declare -x SETUP_CONTRACT_IMAGE_TAG=${SETUP_CONTRACT_IMAGE_TAG:-latest}
declare -x NAMESPACE=${NAMESPACE:-local}
declare -x BEEKEEPER_CLUSTER=${BEEKEEPER_CLUSTER:-local}

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

    if ! command -v beekeeper &> /dev/null; then
        echo "beekeeper is missing..."
        echo "installing beekeeper..."
        mkdir -p "$(go env GOPATH)/bin"
        make beekeeper BEEKEEPER_INSTALL_DIR="$(go env GOPATH)/bin"
    fi

    if [[ -n $CI ]]; then
        if ! command -v k3s &> /dev/null; then
            echo "k3s is missing..."
            echo "installing k3s..."
            if [[ ! -d "${K3S_FOLDER}" ]]; then
                mkdir -p "${K3S_FOLDER}"
                curl -sL https://get.k3s.io -o "${K3S_FOLDER}"/k3s_install.sh
                curl -sL https://github.com/k3s-io/k3s/releases/download/"${K3S_VERSION/+/%2B}"/k3s -o "${K3S_FOLDER}"/k3s
                curl -sL https://github.com/k3s-io/k3s/releases/download/"${K3S_VERSION/+/%2B}"/k3s-airgap-images-amd64.tar -o "${K3S_FOLDER}"/k3s-airgap-images-amd64.tar
            fi
            if [[ ! -d "${K3S_FOLDER}/k3s-images" ]]; then
                mkdir -p "${K3S_FOLDER}/k3s-images"
                curl -sL https://github.com/k3s-io/k3s/releases/download/"${K3S_VERSION/+/%2B}"/k3s-images.txt -o "${K3S_FOLDER}"/k3s-images/k3s-images.txt
                while read -r image; do docker pull "${image}"; done < "${K3S_FOLDER}"/k3s-images/k3s-images.txt
                while read -r image; do docker tag "${image}" k3d-registry.localhost:5000/rancher/"${image##*\/}"; done < "${K3S_FOLDER}"/k3s-images/k3s-images.txt
                while read -r image; do docker save k3d-registry.localhost:5000/rancher/"${image##*\/}" > "${K3S_FOLDER}"/k3s-images/k3s-airgap-"${image##*\/}"-amd64.tar; done < "${K3S_FOLDER}"/k3s-images/k3s-images.txt
            fi
            sudo mkdir -p /etc/rancher/k3s/
            sudo mkdir -p /var/lib/rancher/k3s/agent/images/
            sudo mkdir -p /var/lib/rancher/k3s/server/manifests/
            sudo cp "${K3S_FOLDER}"/k3s /usr/local/bin/k3s
            sudo cp "${K3S_FOLDER}"/k3s-airgap-images-amd64.tar /var/lib/rancher/k3s/agent/images/
            sudo chmod +x "${K3S_FOLDER}"/k3s_install.sh /usr/local/bin/k3s
        fi
    else
        if ! command -v k3d &> /dev/null; then
            echo "k3d is missing..."
            echo "installing k3d..."
            curl -sSL https://raw.githubusercontent.com/rancher/k3d/main/install.sh | TAG=v5.8.3 bash
        fi
    fi
}

config() {
    if [[ -z $LOCAL_CONFIG ]]; then
        BEE_TEMP=$(mktemp -d -t bee-XXX)
        trap 'rm -rf ${BEE_TEMP}' EXIT
        curl -sSL https://raw.githubusercontent.com/ethersphere/beelocal/"${BEELOCAL_BRANCH}"/config/k3d.yaml -o "${BEE_TEMP}"/k3d.yaml
        curl -sSL https://raw.githubusercontent.com/ethersphere/beelocal/"${BEELOCAL_BRANCH}"/config/geth-swap.yaml -o "${BEE_TEMP}"/geth-swap.yaml
        curl -sSL https://raw.githubusercontent.com/ethersphere/beelocal/"${BEELOCAL_BRANCH}"/config/traefik-config.yaml -o "${BEE_TEMP}"/traefik-config.yaml
        if [[ -n $CI ]]; then
            curl -sSL https://raw.githubusercontent.com/ethersphere/beelocal/"${BEELOCAL_BRANCH}"/hack/registries.yaml -o "${BEE_TEMP}"/registries.yaml
            sudo cp "${BEE_TEMP}"/registries.yaml /etc/rancher/k3s/registries.yaml
        fi
        BEE_CONFIG="${BEE_TEMP}"
    fi
}

k8s-local() {
    config
    if [[ -n $CI ]]; then
        echo "starting k3s cluster..."
        if [[ -f  "${K3S_FOLDER}"/k3s-airgap-registry-container-amd64.tar ]]; then
            docker import --change 'ENTRYPOINT ["/entrypoint.sh"]' --change 'CMD ["/etc/docker/registry/config.yml"]' "${K3S_FOLDER}"/k3s-airgap-registry-container-amd64.tar registry:2
        elif [[ -f  "${K3S_FOLDER}"/k3s-airgap-registry-amd64.tar ]]; then
            docker load < "${K3S_FOLDER}"/k3s-airgap-registry-amd64.tar
        fi
        docker container run -d --name k3d-registry.localhost --restart always -p 5000:5000 registry:2 || true
        if [[ ! -f  "${K3S_FOLDER}"/k3s-airgap-registry-amd64.tar ]]; then
            docker save registry > "${K3S_FOLDER}"/k3s-airgap-registry-amd64.tar
        fi
        if [[ ! -f  "${K3S_FOLDER}"/k3s-airgap-registry-container-amd64.tar ]] && [[ -d "${K3S_FOLDER}/k3s-images" ]]; then
            while read -r image; do docker load < "${K3S_FOLDER}"/k3s-images/k3s-airgap-"${image##*\/}"-amd64.tar; done < "${K3S_FOLDER}"/k3s-images/k3s-images.txt
            while read -r image; do docker push k3d-registry.localhost:5000/rancher/"${image##*\/}"; done < "${K3S_FOLDER}"/k3s-images/k3s-images.txt
        fi
        if [[ ! -f  "${K3S_FOLDER}"/k3s-airgap-registry-container-amd64.tar ]]; then
            docker export k3d-registry.localhost > "${K3S_FOLDER}"/k3s-airgap-registry-container-amd64.tar
        fi
        GETH_VERSION=$(grep "tag: v" "${BEE_CONFIG}"/geth-swap.yaml | cut -d' ' -f4)
        if [[ ! -f "${K3S_FOLDER}"/k3s-airgap-client-go:"${GETH_VERSION}"-amd64.tar ]]; then
            rm "${K3S_FOLDER}"/k3s-airgap-client-go:*-amd64.tar || true
            docker pull ethereum/client-go:"${GETH_VERSION}"
            docker tag ethereum/client-go:"${GETH_VERSION}" k3d-registry.localhost:5000/ethereum/client-go:"${GETH_VERSION}"
            docker save k3d-registry.localhost:5000/ethereum/client-go:"${GETH_VERSION}" > "${K3S_FOLDER}"/k3s-airgap-client-go:"${GETH_VERSION}"-amd64.tar
        else
            docker load < "${K3S_FOLDER}"/k3s-airgap-client-go:"${GETH_VERSION}"-amd64.tar
            docker push k3d-registry.localhost:5000/ethereum/client-go:"${GETH_VERSION}"
        fi
        if [[ -z $SKIP_LOCAL ]]; then
            build &
        fi
        INSTALL_K3S_SKIP_DOWNLOAD=true K3S_KUBECONFIG_MODE="644" "${K3S_FOLDER}"/k3s_install.sh
        export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
        echo "waiting for the cluster..."
        until [[ $(kubectl get nodes --no-headers | cut -d' ' -f1) == "${HOSTNAME}" ]]; do sleep 1; done
        kubectl label --overwrite node "${HOSTNAME}" node-group=local || true
        echo "k3s cluster started..."
        if [[ -z $SKIP_LOCAL ]]; then
            # Wait for build
            wait
        fi
    else
        echo "starting k3d cluster..."
        k3d registry create registry.localhost -p 5000 || true
        if [[ -z $SKIP_LOCAL ]]; then
            build &
        fi
        k3d cluster create --config "${BEE_CONFIG}"/k3d.yaml || true
        echo "waiting for the cluster..."
        until k3d kubeconfig get bee; do sleep 1; done
        echo "k3d cluster started..."
        if [[ -z $SKIP_LOCAL ]]; then
            # Wait for build
            wait
        fi
    fi
    if [[ $(helm repo list) != *ethersphere* ]]; then
        helm repo add ethersphere https://ethersphere.github.io/helm &> /dev/null
    fi
    helm repo update ethersphere &> /dev/null
    echo "waiting for the ingressroute crd..."
    until kubectl get crd ingressroutes.traefik.containo.us &> /dev/null; do sleep 1; done
    # Install geth while waiting for traefik
    geth &
    echo "waiting for the kube-system..."
    until kubectl get svc traefik -n kube-system &> /dev/null; do sleep 1; done
    # Wait for geth
    wait
    configure-traefik
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
        if [ ! -f bee ]; then
            make binary
            mv dist/bee bee
        fi
        if [[ -z $SKIP_PUSH ]]; then
            docker buildx build --push -t k3d-registry.localhost:5000/ethersphere/bee:"${IMAGE_TAG}" -f Dockerfile.goreleaser  \
                --cache-to type=gha,mode=max,ref=k3d-registry.localhost:5000/ethersphere/bee,compression=estargz \
                --cache-from type=gha,ref=k3d-registry.localhost:5000/ethersphere/bee .
        else
            docker buildx build -t k3d-registry.localhost:5000/ethersphere/bee:"${IMAGE_TAG}" -f Dockerfile.goreleaser  \
                --cache-from type=gha,ref=k3d-registry.localhost:5000/ethersphere/bee .
        fi
    else
        make docker-build BEE_IMAGE=k3d-registry.localhost:5000/ethersphere/bee:"${IMAGE_TAG}"
    fi
    if [[ -z $SKIP_PUSH ]]; then
        docker push k3d-registry.localhost:5000/ethersphere/bee:"${IMAGE_TAG}"
    fi
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
    beekeeper create bee-cluster --cluster-name "${BEEKEEPER_CLUSTER}"
}

uninstall() {
    echo "uninstalling bee and geth releases..."
    beekeeper delete bee-cluster --cluster-name "${BEEKEEPER_CLUSTER}" || true
    helm uninstall geth-swap -n "${NAMESPACE}" || true
    echo "uninstalled bee and geth releases..."
}

geth() {
    if helm get values geth-swap -n "${NAMESPACE}" -o json &> /dev/null; then # if release exists doesn't install geth
        echo "geth already installed..."
    else
        echo "installing geth..."
        helm install geth-swap ethersphere/geth-swap --create-namespace -n "${NAMESPACE}" -f "${BEE_CONFIG}"/geth-swap.yaml --set imageSetupContract.repository="${SETUP_CONTRACT_IMAGE}" --set imageSetupContract.tag="${SETUP_CONTRACT_IMAGE_TAG}" ${GETH_HELM_OPTS}
        echo "waiting for the geth init..."
        until [[ $(kubectl get pod -n "${NAMESPACE}" -l job-name=geth-swap-setupcontracts -o json | jq -r '.items|last|.status.containerStatuses[0].state.terminated.reason' 2>/dev/null) == "Completed" ]]; do sleep 1; done
        echo "installed geth..."
    fi
}

configure-traefik() {
    if [[ -z $BEE_CONFIG ]]; then
        config
    fi
    echo "configuring Traefik with custom timeouts..."
    
    # Check for valid config files in order of preference
    local config_file=""
    
    # First try local config file
    if [[ -f "./config/traefik-config.yaml" ]] && grep -q "apiVersion:" "./config/traefik-config.yaml"; then
        config_file="./config/traefik-config.yaml"
        echo "Using local traefik-config.yaml"
    # Then try temp config file if it's valid
    elif [[ -f "${BEE_CONFIG}/traefik-config.yaml" ]] && grep -q "apiVersion:" "${BEE_CONFIG}/traefik-config.yaml"; then
        config_file="${BEE_CONFIG}/traefik-config.yaml"
        echo "Using downloaded traefik-config.yaml"
    fi
    
    if [[ -n "$config_file" ]]; then
        kubectl apply -f "$config_file" || echo "Warning: Failed to apply Traefik config"
        echo "waiting for Traefik to restart with new configuration..."
        kubectl rollout restart deployment/traefik -n kube-system || echo "Warning: Failed to restart Traefik"
        kubectl rollout status deployment/traefik -n kube-system --timeout=120s || echo "Warning: Traefik rollout status check failed"
        echo "Traefik configuration applied successfully"
        echo "Current Traefik timeout settings:"
        kubectl describe deployment traefik -n kube-system | grep -E "entryPoints.*timeout" || echo "No timeout settings found in deployment description"
    else
        echo "Info: No valid Traefik config file found, using default timeouts"
        echo "Looked for valid configs in: ${BEE_CONFIG}/traefik-config.yaml and ./config/traefik-config.yaml"
        # Don't exit with error when called from k8s-local, just use defaults
        if [[ "${FUNCNAME[1]}" != "k8s-local" ]]; then
            exit 1
        fi
    fi
}

stop() {
    if [[ -n $CI ]]; then
        echo "action not supported for CI"
        exit 1
    fi
    echo "stoping k3d cluster..."
    k3d cluster stop bee 
    docker stop k3d-registry.localhost
    echo "stopped k3d cluster..."
}

start() {
    if [[ -n $CI ]]; then
        echo "action not supported for CI"
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
        docker rm -f k3d-registry.localhost || true
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
    del-hosts
}

add-hosts() {
    if ! grep -q 'swarm bee' /etc/hosts; then
        hosts_header="# Added by beelocal\n# This entries are to expose swarm bee services inside k3d cluster to the localhost\n"
        hosts_footer="\n# End of beelocal section\n"
        hosts_entry="127.0.0.1\tk3d-registry.localhost geth-swap.localhost"
        for ((i=0; i<2; i++)); do hosts_entry="${hosts_entry} bootnode-${i}.localhost bootnode-${i}-debug.localhost"; done
        for ((i=0; i<5; i++)); do hosts_entry="${hosts_entry} bee-${i}.localhost bee-${i}-debug.localhost"; done
        for ((i=0; i<2; i++)); do hosts_entry="${hosts_entry} light-${i}.localhost light-${i}-debug.localhost"; done
        for ((i=0; i<2; i++)); do hosts_entry="${hosts_entry} restricted-${i}.localhost restricted-${i}-debug.localhost"; done
        echo -e "${hosts_header}""${hosts_entry}""${hosts_footer}" | sudo tee -a /etc/hosts &> /dev/null
    fi
}

del-hosts() {
    if grep -q 'swarm bee' /etc/hosts; then
        grep -vE 'swarm bee|k3d-registry.localhost|beelocal' /etc/hosts | sudo tee /etc/hosts &> /dev/null
    fi
}

ALLOW_OPTS=(skip-local skip-vet skip-push ci)
for OPT in $OPTS; do
    if [[ " ${ALLOW_OPTS[*]} " == *"$OPT"* ]]; then
        if [[ $OPT == "skip-local" ]]; then
            IMAGE="ethersphere/bee"
            SKIP_LOCAL="true"
        fi
        if [[ $OPT == "skip-vet" ]]; then
            SKIP_VET="true"
        fi
        if [[ $OPT == "skip-push" ]]; then
            SKIP_PUSH="true"
        fi
        if [[ $OPT == "ci" ]]; then
            CI="true"
        fi
    else
        echo "$OPT is unknown option..."
        exit 1
    fi
done

ACTIONS=(build check destroy geth install k8s-local uninstall start stop run prepare add-hosts del-hosts configure-traefik)
if [[ " ${ACTIONS[*]} " == *"$ACTION"* ]]; then
    if [[ $ACTION == "run" ]]; then
        check
        add-hosts
        if [[ $(k3d cluster list bee -o json 2>/dev/null| jq -r .[0].serversRunning) == "0" ]]; then
            start
        elif ! k3d cluster list bee --no-headers &> /dev/null; then
            k8s-local
        fi
        install
    elif [[ $ACTION == "prepare" ]]; then
        check
        add-hosts
        if [[ $(k3d cluster list bee -o json 2>/dev/null| jq -r .[0].serversRunning) == "0" ]]; then
            start
        elif ! k3d cluster list bee --no-headers &> /dev/null; then
            k8s-local
        elif [[ -z $SKIP_LOCAL ]]; then
            build
        fi
    else
        $ACTION
    fi
    exit 0
else
    echo "$ACTION is unknown action..."
    exit 1
fi

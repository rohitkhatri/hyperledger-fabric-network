#!/bin/bash

# Exit on first error, print all commands.
set -e

DIR=$(realpath "$(dirname "${BASH_SOURCE}")")

# Including common functions
source "${DIR}/common.sh"

templatesFolder="${DIR}/templates"

ARCH=`uname -m`

: ${TEMPLATES_CRYPTO_FOLDER:="${templatesFolder}/crypto"}
: ${TEMPLATES_DOCKER_COMPOSE_FOLDER:="${templatesFolder}/docker-compose"}

: ${GENERATED_DOCKER_COMPOSE_FOLDER:=./composer}
: ${GENERATED_ARTIFACTS_FOLDER:=${GENERATED_DOCKER_COMPOSE_FOLDER}/artifacts}
: ${GENERATED_CRYPTO_CONFIG_FOLDER:=${GENERATED_DOCKER_COMPOSE_FOLDER}/crypto-config}

: ${CHANNEL_NAME:="mychannel"}
: ${DOMAIN:="example.com"}
: ${ORG:="a"}

: ${NETWORK_NAME:="digitalproperty-network"}
: ${NETWORK_VERSION:="0.0.1"}
: ${NETWORK_ADMIN:="admin@${NETWORK_NAME}"}
: ${NETWORK_ARCHIVE_FILE:="${NETWORK_NAME}@${NETWORK_VERSION}.bna"}

: ${PEER_ADMIN_USER:="PeerAdmin"}
: ${PEER_ADMIN:="${PEER_ADMIN_USER}@${ORG}"}

if [ -z ${FABRIC_START_TIMEOUT+x} ]; then
    export FABRIC_START_TIMEOUT=15
else
    re='^[0-9]+$'
    if ! [[ ${FABRIC_START_TIMEOUT} =~ ${re} ]] ; then
        echo "FABRIC_START_TIMEOUT: Not a number" >&2; exit 1
    fi
fi

function generateArtifacts() {
    echo "Generating artifacts"

    cryptogen generate --config=./${GENERATED_DOCKER_COMPOSE_FOLDER}/crypto-config.yaml --output=${GENERATED_CRYPTO_CONFIG_FOLDER}

    export FABRIC_CFG_PATH=${GENERATED_DOCKER_COMPOSE_FOLDER}

    configtxgen -profile OrdererGenesis -outputBlock ./${GENERATED_ARTIFACTS_FOLDER}/genesis.block

    configtxgen -profile ${CHANNEL_NAME} -outputCreateChannelTx ./${GENERATED_ARTIFACTS_FOLDER}/channel.tx -channelID ${CHANNEL_NAME}
}

function generateDockerCompose() {
    echo "Creating docker-compose.yaml file for ${ORG}.${DOMAIN}"

    compose_template=${TEMPLATES_DOCKER_COMPOSE_FOLDER}/docker-compose-template.yaml

    f="${GENERATED_DOCKER_COMPOSE_FOLDER}/docker-compose.yaml"

    ca_secret_key=$(findCASecretKey ${GENERATED_CRYPTO_CONFIG_FOLDER} ${ORG})

    if [[ -z "${ca_secret_key}" ]]; then
       print_error "Secret key was not found for ${ORG}'s CA, please fix and retry"
       exit
    fi

    sed -e "s/DOMAIN/${DOMAIN}/g" -e "s/ORG/${ORG}/g" -e "s/CA_SECRET_KEY/${ca_secret_key}/g" ${compose_template} > ${f}
}

function generateConfigtx() {
    echo "Creating configx.yaml file for ${ORG}.${DOMAIN}"

    compose_template=${TEMPLATES_CRYPTO_FOLDER}/configtx-template.yaml

    f="${GENERATED_DOCKER_COMPOSE_FOLDER}/configtx.yaml"

    sed -e "s/DOMAIN/${DOMAIN}/g" -e "s/ORG/${ORG}/g" -e "s/CHANNEL_NAME/${CHANNEL_NAME}/g" ${compose_template} > ${f}
}

function generateCryptoConfig() {
    echo "Creating crypto-config.yaml file for ${ORG}.${DOMAIN}"

    compose_template=${TEMPLATES_CRYPTO_FOLDER}/crypto-config-template.yaml

    f="${GENERATED_DOCKER_COMPOSE_FOLDER}/crypto-config.yaml"

    sed -e "s/DOMAIN/${DOMAIN}/g" -e "s/ORG/${ORG}/g" ${compose_template} > ${f}
}

function startFabric() {
    print_message "Starting containers"

    ARCH=${ARCH} docker-compose -f "${GENERATED_DOCKER_COMPOSE_FOLDER}/docker-compose.yaml" down
    ARCH=${ARCH} docker-compose -f "${GENERATED_DOCKER_COMPOSE_FOLDER}/docker-compose.yaml" up -d

    echo "sleeping for ${FABRIC_START_TIMEOUT} seconds to wait for fabric to complete start up"
    sleep ${FABRIC_START_TIMEOUT}
}

function createConnectionProfile() {
    print_message "Creating connection.json for PeerAdmin card"

    ORDERER_CA_CERT=$(certToString "${GENERATED_CRYPTO_CONFIG_FOLDER}/ordererOrganizations/${DOMAIN}/orderers/orderer.${DOMAIN}/tls/ca.crt")
    PEER0_CA_CERT=$(certToString "${GENERATED_CRYPTO_CONFIG_FOLDER}/peerOrganizations/${ORG}.${DOMAIN}/peers/peer0.${ORG}.${DOMAIN}/tls/ca.crt")

    f=${GENERATED_DOCKER_COMPOSE_FOLDER}/connection.json

    sed -e "s/DOMAIN/${DOMAIN}/g" -e "s/ORG/${ORG}/g" -e "s/CHANNEL_NAME/${CHANNEL_NAME}/g" -e "s~\"ORDERER_CA_CERT\"~\"${ORDERER_CA_CERT}\"~" -e "s~\"PEER0_CA_CERT\"~\"${PEER0_CA_CERT}\"~" ${templatesFolder}/connection-template.json > ${f}
}

function createPeerAdminCard() {
    print_message "Creating PeerAdmin card"

    MSP_PATH=${GENERATED_CRYPTO_CONFIG_FOLDER}/peerOrganizations/${ORG}.${DOMAIN}/users/Admin@${ORG}.${DOMAIN}/msp

    CERT=${MSP_PATH}/signcerts/Admin@${ORG}.${DOMAIN}-cert.pem
    PRIVATE_KEY=${MSP_PATH}/keystore/*_sk

    echo "Removing ${PEER_ADMIN} If exists!"
    removeCard "${PEER_ADMIN}"
    rm -rf ${GENERATED_DOCKER_COMPOSE_FOLDER}/${PEER_ADMIN}.card

    echo "Creating connection profile for PeerAdmin card"
    createConnectionProfile

    echo "Creating PeerAdmin Card"
    composer card create -p ${GENERATED_DOCKER_COMPOSE_FOLDER}/connection.json -u ${PEER_ADMIN_USER} -c ${CERT} -k ${PRIVATE_KEY} -r ${PEER_ADMIN_USER} -r ChannelAdmin -f ${GENERATED_DOCKER_COMPOSE_FOLDER}/${PEER_ADMIN}.card

    echo "Importing PeerAdmin Card"
    composer card import --file ${GENERATED_DOCKER_COMPOSE_FOLDER}/${PEER_ADMIN}.card
}

# Common functions
function removeArtifacts() {
    rm -rf ${1}
    [[ -d ${1} ]] || mkdir ${1}
    [[ -d ${1}/artifacts ]] || mkdir ${1}/artifacts
}

function findCASecretKey() {
    echo `find ${1}/peerOrganizations/${2}.${DOMAIN}/ca -type f -name "*_sk" 2>/dev/null | sed "s/.*\///"`
}

function createChannel() {
    docker exec peer0.${ORG}.${DOMAIN} peer channel create -o orderer.${DOMAIN}:7050 -c ${CHANNEL_NAME} -f /etc/hyperledger/artifacts/channel.tx --tls --cafile /etc/hyperledger/crypto/orderer/tls/ca.crt
}

function fetchAndJoinChannel() {
    org=$1
    peer=$2

    docker exec ${peer}.${org}.${DOMAIN} peer channel fetch 0 ${CHANNEL_NAME}.block -o orderer.${DOMAIN}:7050 -c ${CHANNEL_NAME} --tls --cafile /etc/hyperledger/crypto/orderer/tls/ca.crt
    docker exec ${peer}.${org}.${DOMAIN} peer channel join -b ${CHANNEL_NAME}.block
}

function joinChannel() {
    org=$1
    peer=$2

    docker exec ${peer}.${org}.${DOMAIN} peer channel join -b ${CHANNEL_NAME}.block
}

function downloadArtifacts() {
    if [ "${REMOTE}" == "true" ]; then
        echo "Download from other machines"
    else
        echo "Copying artifacts from compose directory"
        cp -r ${GENERATED_ARTIFACTS_FOLDER}/* ${GENERATED_ORG2_ARTIFACTS_FOLDER}/
        cp -r ${GENERATED_CRYPTO_CONFIG_FOLDER}/peerOrganizations/${ORG1}.${DOMAIN} ${GENERATED_ORG2_CRYPTO_CONFIG_FOLDER}/peerOrganizations
        cp -r ${GENERATED_CRYPTO_CONFIG_FOLDER}/ordererOrganizations ${GENERATED_ORG2_CRYPTO_CONFIG_FOLDER}
    fi
}

function certToString() {
    _temp=$(<$1)
    echo "${_temp//$'\n'/\\\\n}"
}

function installNetwork() {
    echo "Installing Business Network"
    composer network install --card ${PEER_ADMIN} --archiveFile "${NETWORK_ARCHIVE_FILE}"

    echo "Starting Business Network"
    composer network start --card ${PEER_ADMIN} --networkName ${NETWORK_NAME} --networkVersion ${NETWORK_VERSION} --networkAdmin admin --networkAdminEnrollSecret adminpw --file "${GENERATED_DOCKER_COMPOSE_FOLDER}/${NETWORK_ADMIN}.card"

    echo "Deleting ${NETWORK_ADMIN} card if already exist"
    removeCard "${NETWORK_ADMIN}"

    echo "Import Business Network Admin Card"
    composer card import --file "${GENERATED_DOCKER_COMPOSE_FOLDER}/${NETWORK_ADMIN}.card"

    echo "Ping Business Network to check status"
    composer network ping --card ${NETWORK_ADMIN}
}

function removeCard() {
    card=${1}

    if composer card list --card ${card} > /dev/null; then
        composer card delete --card ${card}
    fi

    rm -rf ~/.composer/cards/${card}
    rm -rf ~/.composer/client-data/${card}
}

function registerHosts() {
    org=${1}

    HOSTS="127.0.0.1 orderer.${DOMAIN} peer0.${org}.${DOMAIN} ca.${org}.${DOMAIN}"
    add_or_update "${HOSTS}" "/etc/hosts"
}

function generateComposerPlaygroundTemplate() {
    template=${TEMPLATES_DOCKER_COMPOSE_FOLDER}/playground-template.yaml
    f="${GENERATED_DOCKER_COMPOSE_FOLDER}/composer-playground.yaml"
    sed -e "s/NETWORK_ADMIN_CARD/${NETWORK_ADMIN}/g" ${template} > ${f}
}

function generateComposerRestServerTemplate() {
    template=${TEMPLATES_DOCKER_COMPOSE_FOLDER}/rest-server-template.yaml
    f="${GENERATED_DOCKER_COMPOSE_FOLDER}/composer-rest-server.yaml"
    sed -e "s/NETWORK_ADMIN_CARD/${NETWORK_ADMIN}/g" ${template} > ${f}
}

function startComposerPlayground() {
    generateComposerPlaygroundTemplate
    docker-compose -f "${GENERATED_DOCKER_COMPOSE_FOLDER}/composer-playground.yaml" up -d
}

function startComposerRestServer() {
    generateComposerRestServerTemplate
    docker-compose -f "${GENERATED_DOCKER_COMPOSE_FOLDER}/composer-rest-server.yaml" up -d
}

function down() {
    if [ -e ${GENERATED_DOCKER_COMPOSE_FOLDER}/docker-compose.yaml ]; then
        ARCH=${ARCH} docker-compose -f "${GENERATED_DOCKER_COMPOSE_FOLDER}/docker-compose.yaml" down
    fi

    if [ -e ${GENERATED_DOCKER_COMPOSE_FOLDER}/composer-playground.yaml ]; then
        docker-compose -f "${GENERATED_DOCKER_COMPOSE_FOLDER}/composer-playground.yaml" down
    fi

    if [ -e ${GENERATED_DOCKER_COMPOSE_FOLDER}/composer-rest-server.yaml ]; then
        docker-compose -f "${GENERATED_DOCKER_COMPOSE_FOLDER}/composer-rest-server.yaml" down
    fi

    removeCard "${PEER_ADMIN}"
    removeChaincode "${ORG}" "${DOMAIN}"
}

# Parsing commandline args
while getopts "h?m:" opt; do
    case "${opt}" in
        h|\?)
        printHelp
        exit 0
        ;;
        m)  MODE=$OPTARG
        ;;
    esac
done

if [ "${MODE}" == "generate" ]; then
    print_message "Generating artifacts"
    removeArtifacts ${GENERATED_DOCKER_COMPOSE_FOLDER}
    generateConfigtx
    generateCryptoConfig
    generateArtifacts
elif [ "${MODE}" == "up" ]; then
    print_message "Starting network"
    generateDockerCompose
    startFabric
    createChannel
    joinChannel ${ORG} "peer0"
    registerHosts ${ORG}
elif [ "${MODE}" == "down" ]; then
    down
elif [ "${MODE}" == "peeradmin" ]; then
    createPeerAdminCard
elif [ "${MODE}" == "install-network" ]; then
    installNetwork
elif [ "${MODE}" == "composer-playground" ]; then
    startComposerPlayground
elif [ "${MODE}" == "composer-rest-server" ]; then
    startComposerRestServer
else
  echo "Please provide a valid argument!"
  exit 1
fi

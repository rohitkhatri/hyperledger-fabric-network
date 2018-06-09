#!/bin/bash

function print_message() {
    charactor="*"
    msg=$1
    total_length=100
    msg_length=${#msg}
    remaining_length=$(($((total_length-msg_length))-2))
    start_length=$((remaining_length/2))
    end_length=$((remaining_length-start_length))
    
    printf '\n'
    printf $charactor'%.0s' $(seq 1 $start_length)
    printf " $msg "
    printf $charactor'%.0s' $(seq 1 $end_length)
    printf '\n'
}

function print_error() {
    echo "$(tput setaf 1)Error: $1.$(tput sgr0)"
}

function replace_in_file() {
    sed -i '' "s/$1/$2/g" $3
}

function get_input() {
    if ! [[ -z "$1" ]]; then
        echo "$1"
    else
        read -p "$2" _temp

        if [ "$_temp" != '' ]; then
            echo "$_temp"
        else
            echo "$3"
        fi
    fi
}

function add_or_update() {
    updating_string=$1
    file_to_update=$2
    echo $updating_string
    echo $file_to_update
    if ! grep -q "$updating_string" "$file_to_update"; then
        echo -e $updating_string | sudo bash -c 'tee >> '$file_to_update
    fi
}

function downloadBinaries() {
    binaryIncrementalDownload() {
        local BINARY_FILE=$1
        local URL=$2
        curl -f -s -C - ${URL} -o ${BINARY_FILE} || rc=$?

        if [ "$rc" = 22 ]; then
            # looks like the requested file doesn't actually exist so stop here
            return 22
        fi

        if [ -z "$rc" ] || [ $rc -eq 33 ] || [ $rc -eq 2 ]; then
            # The checksum validates that RC 33 or 2 are not real failures
            echo "==> File downloaded. Verifying the md5sum..."
            localMd5sum=$(md5sum ${BINARY_FILE} | awk '{print $1}')
            remoteMd5sum=$(curl -s ${URL}.md5)

            if [ "$localMd5sum" == "$remoteMd5sum" ]; then
                echo "==> Extracting ${BINARY_FILE}..."
                tar xzf ./${BINARY_FILE} --overwrite
                echo "==> Done."
                rm -f ${BINARY_FILE} ${BINARY_FILE}.md5
            else
                echo "Download failed: the local md5sum is different from the remote md5sum. Please try again."
                rm -f ${BINARY_FILE} ${BINARY_FILE}.md5
                exit 1
            fi
        else
            echo "Failure downloading binaries (curl RC=$rc). Please try again and the download will resume from where it stopped."
            exit 1
        fi
    }

    binaryDownload() {
        local BINARY_FILE=$1
        local URL=$2
        echo "===> Downloading: " ${URL}
        # Check if a previous failure occurred and the file was partially downloaded
        if [ -e ${BINARY_FILE} ]; then
            echo "==> Partial binary file found. Resuming download..."
            binaryIncrementalDownload ${BINARY_FILE} ${URL}
        else
            curl ${URL} | tar xz || rc=$?
            
            if [ ! -z "$rc" ]; then
                echo "==> There was an error downloading the binary file. Switching to incremental download."
                echo "==> Downloading file..."
                binaryIncrementalDownload ${BINARY_FILE} ${URL}
            else
                echo "==> Done."
            fi
        fi
    }

    VERSION=1.1.0

    if ! [ -z "$1" ]; then
        VERSION=$1
    fi

    CA_VERSION=$VERSION
    ARCH=$(echo "$(uname -s|tr '[:upper:]' '[:lower:]'|sed 's/mingw64_nt.*/windows/')-$(uname -m | sed 's/x86_64/amd64/g')")

    BINARY_FILE=hyperledger-fabric-${ARCH}-${VERSION}.tar.gz
    CA_BINARY_FILE=hyperledger-fabric-ca-${ARCH}-${CA_VERSION}.tar.gz

    echo "===> Downloading version ${VERSION} platform specific fabric binaries"
    binaryDownload ${BINARY_FILE} https://nexus.hyperledger.org/content/repositories/releases/org/hyperledger/fabric/hyperledger-fabric/${ARCH}-${VERSION}/${BINARY_FILE}
    
    if [ $? -eq 22 ]; then
        echo
        echo "------> ${VERSION} platform specific fabric binary is not available to download <----"
        echo
    fi

    if [ "$2" != "false" ]; then
        echo "===> Downloading version ${CA_VERSION} platform specific fabric-ca-client binary"
        binaryDownload ${CA_BINARY_FILE} https://nexus.hyperledger.org/content/repositories/releases/org/hyperledger/fabric-ca/hyperledger-fabric-ca/${ARCH}-${CA_VERSION}/${CA_BINARY_FILE}
        
        if [ $? -eq 22 ]; then
            echo
            echo "------> ${CA_VERSION} fabric-ca-client binary is not available to download  (Available from 1.1.0-rc1) <----"
            echo
        fi
    fi

    sudo mkdir -p ~/fabric-ca
    sudo mv bin ~/fabric-ca/
    sudo mv config ~/fabric-ca/
    export PATH=~/fabric-ca/bin:$PATH
    echo -e 'export PATH=~/fabric-ca/bin:$PATH' | sudo bash -c 'tee >> ~/.bashrc'
}

function removeChaincode() {
    org=${1}
    domain=${2}

    IMAGES=$(docker images dev-*.${org}.${domain}* -q)
    CONTAINERS=$(docker ps -f name=dev-*.${org}*.*${domain}* -q)

    if [ ${CONTAINERS} ]; then
        docker kill ${CONTAINERS}
    fi

    CONTAINERS=$(docker ps -f name=dev-*.${org}*.*${domain}* -q -a)

    if [ ${CONTAINERS} ]; then
        docker rm ${CONTAINERS}
    fi

    if [ ${IMAGES} ]; then
        docker rmi ${IMAGES}
    fi
}
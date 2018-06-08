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
    #Download Binaries
    sudo mkdir -p ~/fabric-ca
    sudo wget -O ~/fabric-ca/bootstrap.sh https://raw.githubusercontent.com/hyperledger/fabric/master/scripts/bootstrap.sh
    sudo chmod +x ~/fabric-ca/bootstrap.sh
    sudo ~/fabric-ca/bootstrap.sh ${1} -s -d
    sudo mv bin ~/fabric-ca/
    sudo mv config ~/fabric-ca/
    export PATH=~/fabric-ca/bin:$PATH
    echo -e 'export PATH=~/fabric-ca/bin:$PATH' | sudo bash -c 'tee >> ~/.bashrc'
}

function removeChaincode() {
    org=${1}
    domain=${2}

    IMAGES=$(docker images -q)
    CONTAINERS=$(docker ps -a -q)

    for container in ${CONTAINERS[*]}
    do
        IS_DEV=$(docker inspect ${container} | grep -o "dev-[a-z0-9A-Z]*.${org}.${domain}")
        
        if [ "${IS_DEV}" ]; then
            docker kill ${container}
            docker rm ${container}
        fi
    done

    for image in ${IMAGES[*]}
    do
        IS_DEV=$(docker inspect ${image} | grep -o "dev-[a-z0-9A-Z]*.${org}.${domain}")
        
        if [ "${IS_DEV}" ]; then
            docker rmi ${image}
        fi
    done
}
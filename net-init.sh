#!/bin/bash

. .env

echo "WARNING!!! Running the script re-generate genesis block. This will clear all blockchain data"
echo "Are you sure? (yes/no)"
read -p "" -n 4 -r
echo    # (optional) move to a new line
if [[ $REPLY != "yes" ]]
then
    echo "The action wasn't started"
    exit 0
fi

echo "Genesis block re-generating in progress"

# Check if jq is installed
if ! command -v jq &> /dev/null; then
    echo "Error: jq is not installed. Please install jq first."
    exit 1
fi
# Check if curl is installed
if ! command -v curl &> /dev/null; then
    echo "Error: curl is not installed. Please install curl first."
    exit 1
fi

trap 'echo "Error on line $LINENO"; exit 1' ERR
# Function to handle the cleanup
cleanup() {
    echo "Caught Ctrl+C. Killing active background processes and exiting."
    kill $(jobs -p)  # Kills all background processes started in this script
    exit
}
# Trap the SIGINT signal and call the cleanup function when it's caught
trap 'cleanup' SIGINT

# Reset the data from any previous runs and kill any hanging runtimes
rm -rf "$NETWORK_DIR" || echo "no network directory"
mkdir -p $NETWORK_DIR
pkill geth || echo "No existing geth processes"
pkill beacon-chain || echo "No existing beacon-chain processes"
pkill validator || echo "No existing validator processes"
pkill bootnode || echo "No existing bootnode processes"


# Create the bootnode for execution client peer discovery. 
# Not a production grade bootnode. Does not do peer discovery for consensus client
mkdir -p $NETWORK_DIR/bootnode

$GETH_BOOTNODE_BINARY -genkey $NETWORK_DIR/bootnode/nodekey


# Generate the genesis. This will generate validators based
# on https://github.com/ethereum/eth2.0-pm/blob/a085c9870f3956d6228ed2a40cd37f0c6580ecd7/interop/mocked_start/README.md
$PRYSM_CTL_BINARY testnet generate-genesis \
    --fork=deneb \
    --num-validators=$NUM_NODES \
    --chain-config-file=./config.yml \
    --geth-genesis-json-in=./genesis.json \
    --output-ssz=$NETWORK_DIR/genesis.ssz \
    --geth-genesis-json-out=$NETWORK_DIR/genesis.json

# Init all nodes in a loop
for (( i=0; i<$NUM_NODES; i++ )); do
    NODE_DIR=$NETWORK_DIR/node-$i
    mkdir -p $NODE_DIR/execution
    mkdir -p $NODE_DIR/consensus
    mkdir -p $NODE_DIR/logs

    # We use an empty password. Do not do this in production
    geth_pw_file="$NODE_DIR/geth_password.txt"
    echo "" > "$geth_pw_file"

    # Copy the same genesis and inital config the node's directories
    # All nodes must have the same genesis otherwise they will reject eachother
    cp ./config.yml $NODE_DIR/consensus/config.yml
    cp $NETWORK_DIR/genesis.ssz $NODE_DIR/consensus/genesis.ssz
    cp $NETWORK_DIR/genesis.json $NODE_DIR/execution/genesis.json

    # Create the secret keys for this node and other account details
    $GETH_BINARY account new --datadir "$NODE_DIR/execution" --password "$geth_pw_file"

    # Prepayed address for test purposes  
    cp ./address.test $NODE_DIR/execution/keystore

    # Initialize geth for this node. Geth uses the genesis.json to write some initial state
    $GETH_BINARY init \
        --datadir=$NODE_DIR/execution \
        $NODE_DIR/execution/genesis.json
done

echo "New clear network initialized. Nodes ($NUM_NODES) are ready to be started."

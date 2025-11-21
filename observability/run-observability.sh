#!/bin/bash
# run-observability.sh

ACTION=${1:-install}

if [[ "$ACTION" == "install" && -z "$PROMETHEUS_REMOTE_WRITE_URL" ]]; then
    echo "Error: PROMETHEUS_REMOTE_WRITE_URL is not set"
    exit 1
fi

CONTROLLER_NODE=$(scontrol show config | grep -i SlurmctldHost | awk -F'[=(]' '{print $2}')
CURRENT_NODE=$(hostname -s)

echo "Running on: $CURRENT_NODE"

if [[ "$CURRENT_NODE" == "$CONTROLLER_NODE" ]]; then
    echo "${ACTION^}ing on controller node"
    if [[ "$ACTION" == "install" ]]; then
        sudo python3 install_observability.py --node-type controller --prometheus-remote-write-url $PROMETHEUS_REMOTE_WRITE_URL $ARG_ADVANCED
    else
        sudo python3 stop_observability.py --node-type controller
    fi
else
    echo "${ACTION^}ing on compute node"
    if [[ "$ACTION" == "install" ]]; then
        sudo python3 install_observability.py --node-type compute --prometheus-remote-write-url $PROMETHEUS_REMOTE_WRITE_URL $ARG_ADVANCED
    else
        sudo python3 stop_observability.py --node-type compute
    fi
fi
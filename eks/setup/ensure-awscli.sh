#!/bin/bash

# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

# ensure-awscli.sh
#
# Installs the latest AWS CLI v2 before the config scripts run.
#
# Why this exists:
#   HyperPod-on-EKS exposes the EKS cluster ARN under the
#   `Orchestrator.Eks.ClusterArn` field of `aws sagemaker describe-cluster`.
#   Older AWS CLI builds (e.g. 2.17.x, Aug 2024) ship a botocore service
#   model that has NO `Orchestrator` field at all, so the query silently
#   returns "None" and the config scripts fail with a misleading
#   "Could not find EKS cluster" error. Installing the latest CLI fixes it.
#
# Behavior:
#   Always installs the latest AWS CLI v2 (no version guessing, no prompt).
#   Set SKIP_AWSCLI_INSTALL=1 to skip this entirely (e.g. offline / air-gapped).
#
# Platforms: Linux (Ubuntu / Amazon Linux are identical) and macOS.

ensure_awscli() {
    if [ "${SKIP_AWSCLI_INSTALL:-0}" = "1" ]; then
        echo "[INFO] SKIP_AWSCLI_INSTALL=1 — skipping AWS CLI install"
        return 0
    fi

    local os arch url tmp sudo_cmd update_flag
    os="$(uname -s)"

    # curl is required to download the installer.
    if ! command -v curl >/dev/null 2>&1; then
        echo "[ERROR] 'curl' is required to install the AWS CLI but was not found." >&2
        return 1
    fi

    # sudo is needed unless we are already root.
    sudo_cmd=""
    if [ "$(id -u)" -ne 0 ]; then
        if command -v sudo >/dev/null 2>&1; then
            sudo_cmd="sudo"
        else
            echo "[ERROR] Need root or 'sudo' to install the AWS CLI." >&2
            return 1
        fi
    fi

    tmp="$(mktemp -d)" || { echo "[ERROR] mktemp failed" >&2; return 1; }

    case "$os" in
        Linux)
            if ! command -v unzip >/dev/null 2>&1; then
                echo "[ERROR] 'unzip' is required to install the AWS CLI but was not found." >&2
                rm -rf "$tmp"; return 1
            fi
            arch="$(uname -m)"
            case "$arch" in
                x86_64|amd64)  url="https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" ;;
                aarch64|arm64) url="https://awscli.amazonaws.com/awscli-exe-linux-aarch64.zip" ;;
                *) echo "[ERROR] Unsupported Linux architecture: $arch" >&2; rm -rf "$tmp"; return 1 ;;
            esac
            echo "[INFO] Installing latest AWS CLI v2 ($arch)..."
            if ! curl -fsSL "$url" -o "$tmp/awscliv2.zip"; then
                echo "[ERROR] Failed to download AWS CLI from $url" >&2; rm -rf "$tmp"; return 1
            fi
            unzip -q "$tmp/awscliv2.zip" -d "$tmp" || { echo "[ERROR] unzip failed" >&2; rm -rf "$tmp"; return 1; }
            # --update lets the install overwrite an existing AWS CLI.
            update_flag=""
            [ -d /usr/local/aws-cli ] && update_flag="--update"
            echo "[INFO] Running installer (this may prompt for sudo)..."
            $sudo_cmd "$tmp/aws/install" $update_flag --bin-dir /usr/local/bin --install-dir /usr/local/aws-cli \
                || { echo "[ERROR] AWS CLI install failed" >&2; rm -rf "$tmp"; return 1; }
            ;;
        Darwin)
            # The macOS pkg is universal (Intel + Apple Silicon) — no arch split.
            echo "[INFO] Installing latest AWS CLI v2 (macOS pkg)..."
            if ! curl -fsSL "https://awscli.amazonaws.com/AWSCLIV2.pkg" -o "$tmp/AWSCLIV2.pkg"; then
                echo "[ERROR] Failed to download AWS CLI pkg" >&2; rm -rf "$tmp"; return 1
            fi
            echo "[INFO] Running installer (this may prompt for sudo)..."
            $sudo_cmd installer -pkg "$tmp/AWSCLIV2.pkg" -target / \
                || { echo "[ERROR] AWS CLI install failed" >&2; rm -rf "$tmp"; return 1; }
            ;;
        *)
            echo "[ERROR] Unsupported OS for auto-install: $os" >&2; rm -rf "$tmp"; return 1
            ;;
    esac

    rm -rf "$tmp"
    hash -r 2>/dev/null || true   # forget cached path to any old aws binary
    echo "[INFO] AWS CLI now: $(aws --version 2>&1)"
    return 0
}

# Allow running this file directly: ./ensure-awscli.sh
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    ensure_awscli
fi

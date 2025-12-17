#!/bin/bash

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    echo "Error: This script must be sourced, not executed directly."
    echo "Usage: source ${0}  OR  . ${0}"
    exit 1
fi

if [ -f "$HOME/.local/bin/env" ]; then
    source "$HOME/.local/bin/env"
fi

if ! command -v uv &> /dev/null; then
    echo "uv is not installed. Installing uv..."
    curl -LsSf https://astral.sh/uv/install.sh | sh

    if [ $? -ne 0 ]; then
        echo "Error: Failed to install uv."
        return 1
    fi

    if [ -f "$HOME/.local/bin/env" ]; then
        source "$HOME/.local/bin/env"
    fi

    echo "uv installed successfully!"
else
    echo "uv is already installed."
fi

uv sync

if [ -f ".venv/bin/activate" ]; then
    echo "Activating virtual environment..."
    source .venv/bin/activate
    echo "Virtual environment activated! ($(which python))"
else
    echo "Error: Could not find .venv/bin/activate"
    return 1
fi

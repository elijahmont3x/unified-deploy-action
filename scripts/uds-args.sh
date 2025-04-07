#!/bin/bash
# uds-args.sh - Centralized argument parsing utilities for the UDS system

# Default values for common arguments
UDS_DEFAULT_VERBOSE=0
UDS_DEFAULT_DRY_RUN=0
UDS_DEFAULT_CONFIG=""

# Parse common arguments used across UDS scripts
# Usage: parse_common_args "$@"
# Returns: Index of the first non-option argument (to be used for further parsing)
parse_common_args() {
    local OPTIND opt
    
    # Initialize with defaults
    VERBOSE=${UDS_DEFAULT_VERBOSE}
    DRY_RUN=${UDS_DEFAULT_DRY_RUN}
    CONFIG=${UDS_DEFAULT_CONFIG}
    
    while getopts ":hvdc:" opt; do
        case ${opt} in
            h)
                show_help
                exit 0
                ;;
            v)
                VERBOSE=1
                ;;
            d)
                DRY_RUN=1
                ;;
            c)
                CONFIG="$OPTARG"
                ;;
            \?)
                echo "Error: Invalid option: -$OPTARG" >&2
                show_help
                exit 1
                ;;
            :)
                echo "Error: Option -$OPTARG requires an argument" >&2
                show_help
                exit 1
                ;;
        esac
    done
    
    # Export variables so they're available to the caller
    export VERBOSE
    export DRY_RUN
    export CONFIG
    
    # Return the index of the first non-option argument
    return "$OPTIND"
}

# Generic help message function that can be overridden
# Usage: show_help
show_help() {
    echo "Usage: $0 [-h] [-v] [-d] [-c CONFIG] [specific options]"
    echo ""
    echo "Common options:"
    echo "  -h    Show this help message"
    echo "  -v    Enable verbose output"
    echo "  -d    Dry run (don't make actual changes)"
    echo "  -c    Specify configuration file"
    echo ""
    echo "For script-specific options, see below:"
    
    # Call script-specific help if defined
    if type script_specific_help >/dev/null 2>&1; then
        script_specific_help
    fi
}

# Function to validate required arguments
# Usage: validate_required_args "ARG1" "ARG2" ...
validate_required_args() {
    local missing=0
    
    for arg in "$@"; do
        if [ -z "${!arg}" ]; then
            echo "Error: Required argument '$arg' is missing" >&2
            missing=1
        fi
    done
    
    if [ $missing -eq 1 ]; then
        show_help
        exit 1
    fi
    
    return 0
}
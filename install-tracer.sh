# Usage approach template: curl -sSL https://raw.githubusercontent.com/<user>/<repo>/main/install-tracer.sh | bash -s -- --api-key <YOUR_API_KEY>
# Usage approach current: chmod +x install-tracer.sh && ./install-tracer.sh --api-key <API_KEY>

#!/bin/bash

# Globals
API_KEY=""
RESPONSES_LOG="tracer-responses.log"

# Usage function to display help for the script
usage() {
    echo "Usage: $0 --api-key <API_KEY>"
    echo "  --api-key: Mandatory. API key for authentication."
    exit 1
}

# Parses command-line arguments
parse_args() {
    while [[ "$#" -gt 0 ]]; do
        case $1 in
            --api-key) API_KEY="$2"; shift ;;
            *) echo "Unknown parameter passed: $1"; usage ;;
        esac
        shift || true # Advance to the next parameter
    done

    if [[ -z "$API_KEY" ]]; then
        echo "API key is required."
        usage
    fi
}

# Sends an event notification to a specified endpoint and logs the response.
send_event() {
    local event_status="$1"
    local message="$2"
    local response

    response=$(curl -s -w "%{http_code}" -o - \
        --request POST \
        --header "x-api-key: ${API_KEY}" \
        --header 'Content-Type: application/json' \
        --data '{
            "logs": [
                {
                    "message": "'"${message}"'",
                    "event_type": "process_status",
                    "process_type": "installation",
                    "process_status": "'"${event_status}"'"
                }
            ]
        }' \
        "http://app.tracer.bio/api/fluent-bit-webhook")

    # Append the response and HTTP status code to the log
    echo "$response" >> "$RESPONSES_LOG"
}

# Installs Fluent Bit.
install_fluent_bit() {
    # Using curl to download and execute the install script
    curl -sSL https://raw.githubusercontent.com/fluent/fluent-bit/master/install.sh | sh
}

# Creates the Fluent Bit configuration content.
create_fluent_bit_config() {
    cat <<EOF
[SERVICE]
    flush        20
    daemon       Off
    log_level    info
    parsers_file parsers.conf
    plugins_file plugins.conf
    http_server  Off
    http_listen  0.0.0.0
    http_port    2020
    storage.metrics on

[INPUT]
    name cpu
    tag  cpu.local
    interval_sec 30
    
[INPUT]
    name            mem
    tag             mem.local
    interval_sec    30
    
[INPUT]
    name          netif
    tag           netif
    interval_Sec  30
    interval_NSec 0
    interface     eth0


[INPUT]
    name            disk
    tag             disk.local
    interval_sec    30

[INPUT]
    name    tail
    path    /home/ubuntu/.bash_history

# [INPUT]
#     name            systemd
#     Tag             systemd.user

[OUTPUT]
    name    stdout
    format  json
    match   *

[OUTPUT]
    name            http
    match           *
    host            app.tracer.bio
    port            443
    uri             /api/fluent-bit-webhook-without-logs
    format          json
    tls             On
    tls.verify      Off
    header          Content-Type application/json
    header          X-Api-Key ${API_KEY}
EOF
}

# Configures Fluent Bit with a dynamic API key.
configure_fluent_bit() {
    echo 'export PATH=$PATH:/opt/fluent-bit/bin' >> ~/.bashrc
    source ~/.bashrc

    fluent_bit_version=$(fluent-bit --version | grep -oP '^Fluent Bit v\K[\d.]+')
    required_version="3.0.0" # Set to a base comparison version that follows the semantic versioning pattern

    # Convert version numbers to a comparable format by padding shorter versions with zeros
    # This transforms version numbers into a format that can be directly compared
    ver_to_compare=$(echo "$fluent_bit_version" | awk -F. '{ printf("%d%03d%03d", $1, $2, $3); }')
    required_ver_compare=$(echo "$required_version" | awk -F. '{ printf("%d%03d%03d", $1, $2, $3); }')

    # Now compare the padded numbers
    if [ "$ver_to_compare" -le "$required_ver_compare" ]; then
        echo "Fluent Bit version higher than 3.00 is required, but found $fluent_bit_version"
        exit 1
    fi
    
    local config_path="/etc/fluent-bit/fluent-bit.conf"
    local config_content=$(create_fluent_bit_config)

    echo "$config_content" | sudo tee "$config_path" > /dev/null
}

# Updates .bashrc to include Fluent Bit in the PATH
update_bashrc_for_fluent_bit() {
    local fluent_bit_path_entry='export PATH=$PATH:/opt/fluent-bit/bin/fluent-bit'
    # Check if the PATH update is already in .bashrc; if not, append it.
    if ! grep -qF -- "$fluent_bit_path_entry" ~/.bashrc; then
        echo "$fluent_bit_path_entry" >> ~/.bashrc
        echo "Fluent Bit PATH added to .bashrc. Please run 'source ~/.bashrc' or restart your terminal session to apply changes."
    else
        echo "Fluent Bit PATH already in .bashrc."
    fi
}


# Starts Fluent Bit in the background and echoes its PID.
start_fluent_bit() {
    fluent-bit -c /etc/fluent-bit/fluent-bit.conf &
    FLUENT_BIT_PID=$!
    echo "Fluent Bit started with PID: $FLUENT_BIT_PID."
}

# Waits for a specified duration and then stops Fluent Bit.
stop_fluent_bit_after_duration() {
    local duration=$1  # Duration in seconds before stopping Fluent Bit.
    echo "Waiting for $duration seconds before stopping Fluent Bit..."
    sleep "$duration"
    
    if [[ -n $FLUENT_BIT_PID ]] && kill "$FLUENT_BIT_PID" 2>/dev/null; then
        echo "Fluent Bit has been stopped automatically after the timeout."
    else
        echo "Failed to stop Fluent Bit. It may have already been stopped, or the PID was incorrect."
    fi
}



# Main function
main() {
    parse_args "$@"

    # installation
    send_event "start_installation" "Start tracer installation [user vincent]"
    install_fluent_bit
    configure_fluent_bit
    update_bashrc_for_fluent_bit
   
    # start fluent-bit 
    start_fluent_bit
    send_event "finished_installation" "Successfully installed Fluent Bit [user vincent]"
    stop_fluent_bit_after_duration 3600 # default 1 hour 
    send_event "finished_installation" "Fluent Bit has been stopped. [user vincent]"
}

main "$@"

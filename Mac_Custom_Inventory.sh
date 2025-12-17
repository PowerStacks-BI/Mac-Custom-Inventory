#!/bin/bash

# "LogIngestionAPI" (Latest) or "DataCollectorAPI" (Legacy)
LogAPIMode="LogIngestionAPI" 

########## Use for LogIngestionAPI ############

# Replace with your Tenant ID in which the Data Collection Endpoints resides
TenantId="<Enter Your Tenant ID>"

# Replace with your Client ID created and granted permissions
ClientId="<Enter your Client ID>"

# Replace with your secret created for the above client
ClientSecret="<Enter your Client Secret>"

# Replace with your Data Collection Endpoint - Log Ingestion URL
DceURI="<Enter your DCE Log Ingestion URL>"

# Replace with your Data Collection Rule - Immutable ID
DcrImmutableId="<Enter your DCR Immutable ID>"

#################################################

########## Use for DataCollectorAPI ############

# Replace with your Log Analytics Workspace ID
CustomerId="<ENTER YOUR LOG ANALYTICS WORKSPACE ID>"
 
# Replace with your Primary Key
SharedKey="<ENTER YOUR LOG ANALYTICS PRIMARY KEY HERE>"

#################################################

#Control if you want to collect App or Device Inventory or both (True = Collect)
CollectDeviceInventory=true
CollectAppInventory=true
 
# You can use an optional field to specify the timestamp from the data. If the time field is not specified, Azure Monitor assumes the time is the message ingestion time
# DO NOT DELETE THIS VARIABLE. Recommened keep this blank.
TimeStampField=""

#Inventory Date Format (sample "%m-%d %H:%M", "%d-%m %H:%M")
InventoryDateFormat="%m-%d %H:%M"

#endregion initialize
 
#region functions
 
# Function to create the authorization signature
# function New-Signature(customerId, sharedKey, date, contentLength, method, contentType, resource) {
function New-Signature() {
    customerId=$1
    sharedKey=$2
    date=$3
    contentLength=$4
    method=$5
    contentType=$6
    resource=$7
 
    xHeaders="x-ms-date:$date"
    stringToHash="$method\n$contentLength\n$contentType\n$xHeaders\n$resource"
 
    # Convert the message and secret to bytes
    bytesToHash=$(echo -ne "$stringToHash" | xxd -p -u -c 256)
    keyBytes=$(echo "$sharedKey" | base64 -d | xxd -p -u -c 256)
    # Calculate HMAC-SHA256
    calculatedHash=$(echo -n "$bytesToHash" | xxd -r -p | openssl dgst -sha256 -mac HMAC -macopt hexkey:$keyBytes -binary | base64)
 
    authorization=$(echo "SharedKey" $customerId:$calculatedHash)
 
    echo $authorization
    
}
 
# Function to create and post the request using DataCollectorAPI
# function Send-DataCollectorAPI(customerId, sharedKey, body, logType)
function Send-DataCollectorAPI() {
    customerId=$1
    sharedKey=$2
    body=$3
    logType=$4
 
    method="POST"
    contentType="application/json"
    resource="/api/logs"
    rfc1123date=$(date -u +%a,\ %d\ %b\ %Y\ %H:%M:%S\ GMT)
 
    #contentLength=${#body}
    bodyEncoded=$(echo -n "$body" | iconv -f UTF-8 -t WINDOWS-1252 | iconv -f WINDOWS-1252 -t UTF-8)
    contentLength=$(echo -n "$bodyEncoded" | wc -c | tr -d '[:space:]')
    
    signature=$(New-Signature "$customerId" "$sharedKey" "$rfc1123date" "$contentLength" "$method" "$contentType" "$resource")
    uri="https://$customerId.ods.opinsights.azure.com$resource?api-version=2016-04-01"
    
    # Define the maximum payload size limit in bytes
    max_payload_size=$(echo -n "scale=2; 31.9 * 1024 * 1024" | bc)
    # Calculate the payload size in bytes
    payload_size=$(echo "scale=2; $(echo -n "$body"| wc -c)"| bc)
 
    # Convert the payload size to megabytes with one decimal place
    payload_size_mb=$(echo -n "scale=2; $payload_size / 1024 / 1024" | bc)
 
    # Check if the payload size exceeds the limit
    if [ $(bc -l <<< "$payload_size > $max_payload_size") -eq 1 ]; then
        statusmessage="Upload payload is too big and exceeds the 32Mb limit for a single upload. Please reduce the payload size. Current payload size is: $payload_size_mb Mb"
    else
        payloadsize_kb=$(echo "Upload payload size is " $(echo "scale=2; $(echo -n "$body"| wc -c)/ 1024"| bc)"Kb")
 
        response=$(curl --location "$uri" -w "%{http_code}" --header "Authorization: $signature" --header "Log-Type: $logType" --header "x-ms-date: $rfc1123date" --header "time-generated-field;" --header "Content-Type: $contentType" --data "$body" --silent)
 
        statusmessage="$response : $payloadsize_kb"
    fi
 
    echo $statusmessage
}

# Function to create the bearer token
# function New-BearerToken(tenantId, clientId, clientSecret)
function New-BearerToken() {
    tenantId=$1
    clientId=$2
    clientSecret=$3

    scope=$(printf '%s' "https://monitor.azure.com//.default" | jq -sRr @uri)
    body="client_id=$clientId&scope=$scope&client_secret=$clientSecret&grant_type=client_credentials"
    uri="https://login.microsoftonline.com/$tenantId/oauth2/v2.0/token"

    bearerToken=$(curl -s -X POST "$uri" -H "Content-Type: application/x-www-form-urlencoded" -d "$body" | jq -r '.access_token //empty')

    echo $bearerToken
}

# Function to create and post the request using LogIngestionAPI
# function Send-LogIngestionAPI(tenantId, clientId, clientSecret, body, dceURI, dcrImmutableId, logType)
function Send-LogIngestionAPI() {
    tenantId=$1
    clientId=$2
    clientSecret=$3
    body=$4
    dceURI=$5
    dcrImmutableId=$6
    logType=$7

    method="POST"
    contentType="application/json"
    bearerToken=$(New-BearerToken "$tenantId" "$clientId" "$clientSecret")

    uri="$dceURI/dataCollectionRules/$dcrImmutableId/streams/Custom-$logType?api-version=2023-01-01"

    # Define the maximum payload size limit in bytes
    max_payload_size=$(echo -n "scale=2; 0.9 * 1024 * 1024" | bc)
    # Calculate the payload size in bytes
    payload_size=$(echo "scale=2; $(echo -n "$body"| wc -c)"| bc)
 
    # Convert the payload size to megabytes with one decimal place
    payload_size_mb=$(echo -n "scale=2; $payload_size / 1024 / 1024" | bc)
 
    # Check if the payload size exceeds the limit
    if [ $(bc -l <<< "$payload_size > $max_payload_size") -eq 1 ]; then
        statusmessage="Upload payload is too big and exceeds the 1Mb limit for a single upload. Please reduce the payload size. Current payload size is: $payload_size_mb Mb"
    else
        payloadsize_kb=$(echo "Upload payload size is " $(echo "scale=2; $(echo -n "$body"| wc -c)/ 1024"| bc)"Kb")
 
        response=$(curl --location "$uri" -w "%{http_code}" --header "Authorization: Bearer $bearerToken"  --header "Content-Type: $contentType" --data "$body" --silent)
 
        statusmessage="$response : $payloadsize_kb"
    fi
 
    echo $statusmessage
}

#endregion functions
 
#region script
 
#Get Common data for App and Device Inventory:
 
#Get Intune DeviceID and ComputerName
 
# Retrieve Intune DeviceID
ManagedDeviceID=$(security find-certificate -a | awk -F= '/issu/ && /MICROSOFT INTUNE MDM DEVICE CA/ { getline; gsub(/"/, "", $2); print $2}' | head -n 1)
# Retrieve ComputerName
ComputerName=$(scutil --get ComputerName)

#region DEVICEINVENTORY
 
if [ "$CollectDeviceInventory" = true ]; then
    #Set Name of Log
    DeviceLog="PowerStacksDeviceInventory$([[ "$LogAPIMode" == "LogIngestionAPI" ]] && echo "_CL")"
 
    # --- CPU Info ---
    cpu_manufacturer=$(sysctl -n machdep.cpu.vendor 2>/dev/null || echo "Apple")
    cpu_name=$(sysctl -n machdep.cpu.brand_string 2>/dev/null || echo "Apple Silicon")
    if [[ "$cpu_name" == Apple* ]]; then
        cpu_vendor="Apple"
    else
        cpu_vendor=$(sysctl -n machdep.cpu.vendor 2>/dev/null || echo "Intel")
    fi
    cpu_physical=$(sysctl -n hw.packages)
    cpu_cores=$(sysctl -n hw.physicalcpu)
    cpu_logical=$(sysctl -n hw.logicalcpu)
    if [ "$cpu_vendor" != "Apple" ]; then
        cpu_max_clock=$(bc <<< "$(sysctl -n hw.cpufrequency_max)/1000") # MHz
    fi
    # --- Memory ---
    memory=$(sysctl -n hw.memsize)

    # --- Boot Time ---
    last_boot=$(sysctl -n kern.boottime | awk -F '[=,]' '{print $2}' | xargs -I{} date -u -r {} +"%Y-%m-%dT%H:%M:%S.0000000Z")

    # --- Device Info ---
    device_model=$(system_profiler SPHardwareDataType | awk -F': ' '/Model Identifier/{print $2}')
    device_manufacturer="Apple Inc."

    # --- Disk Info ---
    disk_id="disk0"
    disk_info=$(diskutil info "$disk_id")

    # Extract fields
    disk_model=$(echo "$disk_info" | awk -F': ' '/Device \/ Media Name/ {print $2}' | xargs)
    disk_bus=$(echo "$disk_info" | awk -F': ' '/Protocol/ {print $2}'| xargs)
    disk_type=$(echo "$disk_info" | awk -F': *' '/Solid State/ { print ($2 == "Yes" ? "SSD" : "HDD") }')
    disk_size_bytes=$(echo "$disk_info" | awk -F'[()]' '/Disk Size/ {gsub(/[^0-9]/, "", $2); print $2}')
    disk_smart=$(echo "$disk_info" | awk -F': ' '/SMART Status/ {print $2}' | xargs)
    disk_temp=$(ioreg -lw0 | grep -i "temperature" | grep -Eo '[0-9]+' | head -n 1)
    disk_temp="${disk_temp:-0}"
    if [ "$disk_smart" == "Verified" ]; then
        disk_smart="Healthy"
    fi

    # --- Battery Info ---
    battery_data=$(ioreg -r -n AppleSmartBattery)
    if [ "$cpu_vendor" == "Apple" ]; then
        max_capacity=$(echo "$battery_data" | awk '/"AppleRawMaxCapacity" / { print $NF }')
    else
        max_capacity=$(echo "$battery_data" | awk '/"MaxCapacity" / { print $NF }')
    fi
    design_capacity=$(echo "$battery_data" | awk '/"DesignCapacity" / { print $NF }')
    battery_health=""
    if [ -n "$max_capacity" ] && [ -n "$design_capacity" ]; then
        percent=$(echo "scale=2; $max_capacity/$design_capacity*100" | bc)
        battery_health=$(printf "%.2f" "$percent")
    fi

    # --- Build Raw JSON ---
    Inventory="
    {
    \"Memory\": \"$memory\",
    \"CPUManufacturer\": \"$cpu_manufacturer\",
    \"CPUName\": \"$cpu_name\",
    \"CPUMaxClockSpeed\": \"$cpu_max_clock\",
    \"CPUPhysical\": \"$cpu_physical\",
    \"CPUCores\": \"$cpu_cores\",
    \"CPULogical\": \"$cpu_logical\",
    \"LastBootTime\": \"$last_boot\",
    \"BatteryHealthPercent\": \"$battery_health\",
    \"BatteryFullChargedCapacity\": \"$max_capacity\",
    \"BatteryDesignedCapacity\": \"$design_capacity\",
    \"PhysicalDisks\": [
        {
        \"BusType\": \"$disk_bus\",
        \"HealthStatus\": \"$disk_smart\",
        \"Manufacturer\": \"Apple\",
        \"Model\": \"$disk_model\",
        \"Size\": \"$disk_size_bytes\",
        \"Type\": \"$disk_type\",
        \"Temperature\": \"$disk_temp\"
        }
    ],
    \"DeviceManufacturer\": \"$device_manufacturer\",
    \"DeviceModel\": \"$device_model\"
    }"

    DeviceDetailsJson=$(echo -n "$Inventory" | iconv -t utf-8 | gzip -c -n | base64 | tr -d '\n')

    # Define chunk size
    chunk_size=$([[ "$LogAPIMode" == "LogIngestionAPI" ]] && echo 64512 || echo 31744)

    # Split the string into chunks and store in an array
    DeviceDetailsJsonArr=()
    while [ -n "$DeviceDetailsJson" ]; do
        chunk=$(echo "$DeviceDetailsJson" | cut -c 1-$chunk_size)
        DeviceDetailsJsonArr+=("$chunk")
        DeviceDetailsJson=$(echo "$DeviceDetailsJson" | cut -c $(($chunk_size + 1))-)
    done
 
    # Print each chunk
    i=0
    DeviceDetails=""
    for chunk in "${DeviceDetailsJsonArr[@]}"; do
        i=$(echo $i + 1 | bc)
        if [ "$i" == "1" ]; then
            DeviceDetails=$(echo "\"DeviceDetails$i$([[ "$LogAPIMode" == "LogIngestionAPI" ]] && echo "_s")\":\"$chunk\"")
        else
            DeviceDetails="$DeviceDetails,$(echo "\"DeviceDetails$i$([[ "$LogAPIMode" == "LogIngestionAPI" ]] && echo "_s")\":\"$chunk\"")"
        fi
    done
    #echo $DeviceDetails
    
    # Define the maximum devicedetails size limit in bytes
    max_devicedetails_size=$(echo -n "scale=2; 10.0 * $( [[ "$LogAPIMode" == "LogIngestionAPI" ]] && echo "63" || echo "31" ) * 1024" | bc)
    # Calculate the devicedetails size in bytes
    devicedetails_size=$(echo "scale=2; $(echo -n "$DeviceDetails"| wc -c)"| bc)
    # Convert the devicedetails size to kilobytes with one decimal place
    devicedetails_size_kb=$(echo -n "scale=2; $devicedetails_size / 1024" | bc)
 
    if [ $(bc -l <<< "$devicedetails_size > $max_devicedetails_size") -eq 1 ]; then
        echo "DeviceDetails is too big and exceed the $( [[ "$LogAPIMode" == "LogIngestionAPI" ]] && echo "64" || echo "32" )Kb limit per column for a single upload. Please increase number of columns (#10). Current payload size is: $devicedetails_size_kb Kb"
        exit 1
    fi

    MainDevice="[{\"ComputerName$([[ "$LogAPIMode" == "LogIngestionAPI" ]] && echo "_s")\":\"$ComputerName\",\"ManagedDeviceID$([[ "$LogAPIMode" == "LogIngestionAPI" ]] && echo "_g")\":\"$ManagedDeviceID\",$DeviceDetails}]"

    ResponseDeviceInventory=$(
        if [[ "$LogAPIMode" == "LogIngestionAPI" ]]; then
            Send-LogIngestionAPI "$TenantId" "$ClientId" "$ClientSecret" "$MainDevice" "$DceURI" "$DcrImmutableId" "$DeviceLog"
        else
            Send-DataCollectorAPI "$CustomerId" "$SharedKey" "$MainDevice" "$DeviceLog"
        fi
    )
 
fi
#endregion DEVICEINVENTORY

#region APPINVENTORY
 
if [ "$CollectAppInventory" = true ]; then
    #Set Name of Log
    AppLog="PowerStacksAppInventory$([[ "$LogAPIMode" == "LogIngestionAPI" ]] && echo "_CL")"
 
    #installedApps=$(Get-InstalledApplications)
    installedApps=$(system_profiler SPApplicationsDataType -json)
 
    # Use awk to parse JSON data and extract fields
    InstalledAppJson=$(echo "$installedApps" | awk -F'[:,]' '
        $1 ~ /_name/ {
            name = $2
            gsub(/"/, "", name)
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", name)
        }
        $1 ~ /lastModified/ {
            lastModified = $0
            sub(/.*: /, "", lastModified)
            gsub(/"/, "", lastModified)
            gsub(/,$/, "", lastModified)
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", lastModified)
        }
        $1 ~ /path/ {
            path = $2
            gsub(/"/, "", path)
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", path)
        }
        $1 ~ /version/ {
            version = $2
            gsub(/"/, "", version)
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", version)
            print "{\"AppName\":\"" name "\",\"AppVersion\":\"" version "\",\"AppInstallDate\":\"" lastModified "\",\"AppInstallPath\":\"" path "\"}"
        }
    ' | paste -sd "," -)
    
    # Encode to UTF-8, compress, and then encode to base64
    InstalledAppJson=$(echo -n "[$InstalledAppJson]" | iconv -t utf-8 | gzip -c -n | base64 | tr -d '\n')
 
    # Define chunk size
    chunk_size=$([[ "$LogAPIMode" == "LogIngestionAPI" ]] && echo 64512 || echo 31744)
 
    # Split the string into chunks and store in an array
    InstalledAppJsonArr=()
    while [ -n "$InstalledAppJson" ]; do
        chunk=$(echo "$InstalledAppJson" | cut -c 1-$chunk_size)
        InstalledAppJsonArr+=("$chunk")
        InstalledAppJson=$(echo "$InstalledAppJson" | cut -c $(($chunk_size + 1))-)
    done
 
    # Print each chunk
    i=0
    InstalledApps=""
    for chunk in "${InstalledAppJsonArr[@]}"; do
        i=$(echo $i + 1 | bc)
        if [ "$i" == "1" ]; then
            InstalledApps=$(echo "\"InstalledApps$i$([[ "$LogAPIMode" == "LogIngestionAPI" ]] && echo "_s")\":\"$chunk\"")
        else
            InstalledApps="$InstalledApps,$(echo "\"InstalledApps$i$([[ "$LogAPIMode" == "LogIngestionAPI" ]] && echo "_s")\":\"$chunk\"")"
        fi
    done
    #echo $InstalledApps
    
    # Define the maximum installapps size limit in bytes
    max_installapps_size=$(echo -n "scale=2; 10.0 * $( [[ "$LogAPIMode" == "LogIngestionAPI" ]] && echo "63" || echo "31" ) * 1024" | bc)
    # Calculate the installapps size in bytes
    installapps_size=$(echo "scale=2; $(echo -n "$InstalledApps"| wc -c)"| bc)
    # Convert the installapps size to kilobytes with one decimal place
    installapps_size_kb=$(echo -n "scale=2; $installapps_size / 1024" | bc)
 
    if [ $(bc -l <<< "$installapps_size > $max_installapps_size") -eq 1 ]; then
        echo "InstalledApp is too big and exceed the $( [[ "$LogAPIMode" == "LogIngestionAPI" ]] && echo "64" || echo "32" )Kb limit per column for a single upload. Please increase number of columns (#10). Current payload size is: $installapps_size_kb Kb"
        exit 1
    fi
 
    MainApp="[{\"ComputerName$([[ "$LogAPIMode" == "LogIngestionAPI" ]] && echo "_s")\":\"$ComputerName\",\"ManagedDeviceID$([[ "$LogAPIMode" == "LogIngestionAPI" ]] && echo "_g")\":\"$ManagedDeviceID\",$InstalledApps}]"
 
    ResponseAppInventory=$(
        if [[ "$LogAPIMode" == "LogIngestionAPI" ]]; then
            Send-LogIngestionAPI "$TenantId" "$ClientId" "$ClientSecret" "$MainApp" "$DceURI" "$DcrImmutableId" "$AppLog"
        else
            Send-DataCollectorAPI "$CustomerId" "$SharedKey" "$MainApp" "$AppLog"
        fi
    )
 
fi
#endregion APPINVENTORY

#Report back status
 
# Get current date in the specified format
date=$(date -u "+$InventoryDateFormat")
 
# Initialize output message
output_message="InventoryDate: $date"
 
# Check CollectDeviceInventory flag
if [ "$CollectDeviceInventory" = true ]; then
    # Check response for DeviceInventory
    if [[ "$ResponseDeviceInventory" =~ ^$( [[ "$LogAPIMode" == "LogIngestionAPI" ]] && echo "204" || echo "200" )" :" ]]; then
        output_message="$output_message DeviceInventory: OK $ResponseDeviceInventory"
    else
        output_message="$output_message DeviceInventory: Fail - $ResponseDeviceInventory"
        exit 1
    fi
fi
 
# Check CollectAppInventory flag
if [ "$CollectAppInventory" = true ]; then
    # Check response for AppInventory
    if [[ "$ResponseAppInventory" =~ ^$( [[ "$LogAPIMode" == "LogIngestionAPI" ]] && echo "204" || echo "200" )" :" ]]; then
        output_message="$output_message AppInventory: OK $ResponseAppInventory"
    else
        output_message="$output_message AppInventory: Fail - $ResponseAppInventory"
        exit 1
    fi
fi
 
echo "$output_message"
exit 0
 
#endregion script

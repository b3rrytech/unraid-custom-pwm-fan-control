#!/bin/bash

### unRAID Custom PWM Fan Control Script ###
### b3rrytech ###

# Source and base for this script is from @Joseph Trice-Rolph on the unRAID forums. https://forums.unraid.net/topic/114503-custom-pwm-fan-control-script-based-on-disk-temps-using-disksini-to-avoid-drive-spinup/

# Version 2025.05.11 Added to Github repo https://github.com/b3rrytech/unraid-custom-pwm-fan-control
# Version 2025.05.10 Removed data_pool and data_pool2 from excludedDisks since pool is removed from system
# Version 2025.05.03 Added syslog notification if PWM value changes
# Version 2025.05.02 First Setup

##VARIABLES
MIN_PWM=90
LOW_PWM=95
HIGH_PWM=200
MAX_PWM=255
LOW_TEMP=30
HIGH_TEMP=40
MAX_TEMP=45
ARRAY_FAN=/sys/class/hwmon/hwmon7/pwm2
EXHAUST_FAN=/sys/class/hwmon/hwmon7/pwm4

##Disk Types Checked (0 disabled, 1 enabled) ## Available types in disks.ini is Parity, Data, Cache and Flash,
declare -A diskTypesChecked
diskTypesChecked[Parity]=1
diskTypesChecked[Data]=1
diskTypesChecked[Cache]=0
diskTypesChecked[Flash]=0

##Excluded Disks (name as in disk.ini) ## Shouldn't really need to exclude the SSDs since they're excluded above, but I try it anyways.
excludedDisks=(cache_pool,cache_pool2,cache_pool3,sata_pool,sata_pool2,system_pool,system_pool2,flash)


# END OF USER VARIABLES - DON´T CHANGE ANYTHING BELOW THIS LINE #

##Variables
isNumber='^[0-9]+$'

##GET LIST OF ARRAY DISKS
declare -a fullDiskList
while IFS='= ' read var val
do
    if [[ $var == \[*] ]]
    then
        section=${var:2:-2}
        fullDiskList+=($section)
        eval declare -A ${section}_data
    elif [[ $val ]]
    then 
        eval ${section}_data[$var]=$val
    fi
done < /var/local/emhttp/disks.ini

##filter out excluded disks and disk types
declare -a diskList
for disk in "${fullDiskList[@]}"
do
    diskName=${disk}_data[name]
    diskType=${disk}_data[type]
    diskId=${disk}_data[id]
    diskTypeChecked=${diskTypesChecked[${!diskType}]}
    if [[ "${!diskId}" == "" ]] ##ignore unassigned slots
    then
        : ##dont check
    elif [[ "${diskName}" == "${excludedDisks[*]}" ]] ##needs improvement
    then
        : ##dont check
    elif (( ${diskTypeChecked} == 0 ))
    then
        : ##dont check
     else
        diskList+=($disk)
    fi
done



##CHECK DISKS
declare -A diskState
declare -A diskTemp
maxTempC=0
maxTempDisk=null
activeDisks=0

for disk in "${diskList[@]}"
do
    ##check disk state
    eval thisDiskStateVal=${disk}_data[spundown]
    if (( ${thisDiskStateVal} == 1 ))
    then
        thisDiskState=spundown
        diskState[${disk}]=spundown
    else
        thisDiskState=spunup
        diskState[${disk}]=spunup
		activeDisks=$((activeDisks+1))
    fi
    ##check disk temp
    thisDiskTemp=${disk}_data[temp]
	
    if [[ "$thisDiskState" == "spunup" ]]
    then
        if [[ "${!thisDiskTemp}" =~ $isNumber ]]
        then
            diskTemp[${disk}]=${!thisDiskTemp}
            if (( "${!thisDiskTemp}" > "$maxTempC" ))
            then
                maxTempC=${!thisDiskTemp}
                maxTempDisk=$disk
            fi
        else
            diskTemp[$disk]=unknown
        fi
    else
        diskTemp[$disk]=na
    fi
done

echo Hottest Disk is $maxTempDisk at $maxTempC C

##calculate PWM
##maxTempC=26 ##overide temp for manual control
# Linear PWM Logic Variables - do not modify
NUM_STEPS=$((HIGH_TEMP - LOW_TEMP - 1))
PWM_INCREMENT=$(( (HIGH_PWM - LOW_PWM) / NUM_STEPS))

if (( $activeDisks == 0 ))
then
    ##all disks spun down
	echo All drives are idle/spundown, setting fans to minimum.
	FAN_PWM=$MIN_PWM
	
elif (( $maxTempC <= $LOW_TEMP ))
then
    ##if hottest drive below low
	echo $maxTempC C is below low temp of $LOW_TEMP C, setting fans to minimum.
	FAN_PWM=$MIN_PWM

elif (( $maxTempC > $LOW_TEMP && $maxTempC <= $HIGH_TEMP ))
then
    ##if hottest drive above low but below high
	echo $maxTempC C is above low temp of $LOW_TEMP C but below high temp of $HIGH_TEMP C, setting fans to ...
	FAN_PWM=$(( ((maxTempC - LOW_TEMP - 1) * PWM_INCREMENT) + MIN_PWM ))
elif (( $maxTempC > $HIGH_TEMP && $maxTempC <= $MAX_TEMP ))
then
    ##if hottest drive above high but below max
	echo $maxTempC C is above high temp of $HIGH_TEMP C but below max temp of $MAX_TEMP C, setting fans to ...
	FAN_PWM=$MAX_PWM

elif (( $maxTempC > $MAX_TEMP ))
then
    ##if hottest drive exceeds max temp
    ##pause parity/alert
	echo $maxTempC C is above max temp of $MAX_TEMP C, setting fans to full and ...
	FAN_PWM=255

else
    ##if all else fails - full power fans
    echo undefined outcome, setting fans to full and ...
	FAN_PWM=255

fi

echo $FAN_PWM > $ARRAY_FAN
echo $FAN_PWM > $EXHAUST_FAN

echo Fan PWM set to $FAN_PWM for both ARRAY_FAN and EXHAUST_FAN

# Path to the temporary file storing PWM values
PWM_LOG_FILE="/tmp/fan_pwm_values.log"

# Function to append a PWM value to the log file and maintain only the last 4
function log_pwm_value {
    echo "$1" >> "$PWM_LOG_FILE"
    # Keep only the last 4 entries
    tail -n 4 "$PWM_LOG_FILE" > "$PWM_LOG_FILE.tmp" && mv "$PWM_LOG_FILE.tmp" "$PWM_LOG_FILE"
}

# Function to check the last logged PWM value and report changes
function check_pwm_change {
    local last_logged_pwm

    # Read the last logged PWM value
    if [ -f "$PWM_LOG_FILE" ]; then
        last_logged_pwm=$(tail -n 1 "$PWM_LOG_FILE")
    else
        last_logged_pwm=""
    fi

    # Compare the current PWM with the last logged PWM
    if [ "$last_logged_pwm" != "$FAN_PWM" ]; then
        echo "ARRAY_FAN and EXHAUST fan PWM changed to $FAN_PWM" | logger -t Custom_PWM_Fan_Control_Script
    fi
}

# Check for changes and log the current PWM value
check_pwm_change
log_pwm_value "$FAN_PWM"


### DEBUGGING ONLY ###
#for key in "${!diskList[@]}"
#do
#  echo -n "key  : $key, "
#  echo "value: ${diskList[$key]}"
#done
#
#for key in "${!diskTemp[@]}"
#do
#  echo -n "key  : $key, "
#  echo "value: ${diskTemp[$key]}"
#done

#param=temperature
#echo ${!parity_data[@]}
#echo ${!disk2_data[@]}
#echo \*

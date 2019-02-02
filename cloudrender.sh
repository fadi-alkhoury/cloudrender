#!/bin/bash
# Send a render job to a spot instance using your own AMI (see ec2_setup.sh).
# The progress can be observed in std out

instanceType=g4dn.xlarge
blenderOptions=""
blenderOption_f="0"
blenderOption_s=""
blenderOption_e=""
blenderOption_a=""

usageStr="Usage: cloudrender [-c instanceType] [[[-f frame] | [[-s startFrame] [-e endFrame] -a]]"

while getopts c:f:s:e:a option
do	case "$option" in
	c)	instanceType=$OPTARG;;
	f)	blenderOption_f=$OPTARG;;
	s)	blenderOption_s=$OPTARG;;
	e)	blenderOption_e=$OPTARG;;
	a)	blenderOption_a="true";;
	[?])	print >&2 $usageStr
		exit 1;;
	esac
done
if [[ -z $blenderOption_a ]]; then
    if [[ -z $blenderOption_s ]] && [[ -z $blenderOption_e ]]; then
        blenderOptions=" -f $blenderOption_f "
    else
        echo -e "Invalid arguments\n${usageStr}"
		exit 1
    fi
else
    if [[ "$blenderOption_s" != "" ]]; then
        blenderOptions+=" -s $blenderOption_s "
    fi
    if [[ "$blenderOption_e" != "" ]]; then
        blenderOptions+=" -e $blenderOption_e "
    fi
    blenderOptions+=" -a "
fi
echo Using blender options ${blenderOptions}

case $(ps -o stat= -p $$) in
  *+*) echo Initializing render job ;;
  *) zenity --error --text 'This script should run in foreground.' --title 'Error' --width=300
    exit 1;;
esac

projectName=${PWD##*/} 
if [[ $projectName =~ " " ]]
then
    echo "Error: spaces within folder names not supported."
    exit 1
fi

blendFile=$(ls | grep '\.blend$' | head -1)
if [[ -z ${blendFile} ]]; then
    echo -e "\e[1;31m  Error: could not find a .blend file\e[0m"
    exit 1
fi

echo Found blender file ${blendFile}

# Prepare compressed package to be sent to EC2
outPath=./cloudrender/$(date +"%Y%m%d%H%M%S")/
mkdir -p ${outPath}
startTime=$(date +"%s%N")
mkdir -p ~/.cache/cloudrender/${projectName}/${startTime}
rsync -a --exclude 'out' --exclude 'cache_fluid' ./ ~/.cache/cloudrender/${projectName}/${startTime}

scriptPath="$( cd "$(dirname "$0")" >/dev/null 2>&1 ; pwd -P )"
cp $scriptPath/configure_gpu.py ~/.cache/cloudrender/${projectName}/${startTime}/configure.py
tar -C ~/.cache/cloudrender/${projectName}/${startTime} -czf ~/.cache/cloudrender/${projectName}/${startTime}.tar.gz .

# Activate settings for accessing your instance
source $scriptPath/settings.sh

# Defining a function that terminates the instance and does clean up tasks
cleanUp () {
    echo -e "\nTerminating EC2 instance $1"
    aws ec2 terminate-instances --instance-ids $1 --profile ${profile} > /dev/null
    if [[ $? -ne 0 ]]; then
        echo -e "\e[1;31m  CRITICAL FAILURE: Request to terminate EC2 instance did not succeed. You have to manually terminate the instance ${instanceId}. \e[0m"
    fi
    
    rm -rf ~/.cache/cloudrender/${projectName}/${startTime}
    rm ~/.cache/cloudrender/${projectName}/${startTime}*

    endTime=$(date +"%s%N")
    elapsedTimeStr=$(printf "%06d\n" $(((endTime - startTime) / 1000000000)))
    echo "time started: $(date +"%Y%m%d%H%M%S" -d @$(echo $startTime | cut -c1-10))
    instance type: ${instanceType}
    seconds taken: ${elapsedTimeStr}" > ${outPath}/info.txt

    echo -e "Total elapsed time: ${elapsedTimeStr}s\n"
}

# Acquire a spot instance
echo -e "\nAcquiring $instanceType EC2 instance"
instanceId=$(aws ec2 run-instances \
    --image-id ${amiId} \
    --instance-type ${instanceType} \
    --key-name ${keyName} \
    --security-group-ids ${securityGroupId} \
    --instance-market-options '{"MarketType": "spot", "SpotOptions": {"SpotInstanceType": "one-time"}}' \
    --query 'Instances[*].InstanceId' \
    --output text \
    --profile ${profile})
if [[ $? -ne 0 ]]; then
    echo Failed to acquire an EC2 instance. Aborting ...
    rm -rf ~/.cache/cloudrender/${projectName}/${startTime}
    rm ~/.cache/cloudrender/${projectName}/${startTime}*
    exit 1
fi

echo -e "\nWaiting for the instance to be ready"
initialWait=5
sleep ${initialWait}s
instanceState=pending
for i in {0..25..1}
do
    sleep 1s
    instanceState=$(aws ec2 describe-instances --instance-ids ${instanceId}  \
    --query 'Reservations[*].Instances[*].State.Name' \
    --output text \
    --profile ${profile})
    printf "Waited %02ds, state ${instanceState}\n" $(( $initialWait + $i ))
    
    if [[ "$instanceState" == "running" ]]; then
        break
    fi
done
if [[ "$instanceState" != "running" ]]; then
    echo Timed out waiting for instance to be ready. Aborting ...
    cleanUp $instanceId
    exit 1
fi

# Transfer package to instance
instanceAddress=$(aws ec2 describe-instances --instance-ids ${instanceId}  \
    --query 'Reservations[*].Instances[*].[PublicDnsName]' \
    --output text \
    --profile ${profile})

echo -e "\nTransferring files to instance"
scp -i "${keyFile}" \
    -o StrictHostKeyChecking=no \
    -o ConnectTimeout=60 \
    ~/.cache/cloudrender/${projectName}/${startTime}.tar.gz \
    ubuntu@${instanceAddress}:/home/ubuntu/blender_project.tar.gz
if [[ $? -ne 0 ]]; then
    echo Failed to connect to instance. Aborting ...
    cleanUp $instanceId
    exit 1
fi

# Setup periodic sending of results to the local machine
syncInterval=10
echo -e "\nOutput path: ${outPath}"
echo -e "Render results will be saved to this folder every ${syncInterval} seconds \n"
watch -n ${syncInterval} "rsync -aze \"ssh -i ${keyFile}\" ubuntu@${instanceAddress}:~/out/ ${outPath}" &> /dev/null &

# Log in and start the rendering
echo Logging in to EC2 instance
ssh -i "${keyFile}" -o StrictHostKeyChecking=no -o ConnectTimeout=60 ubuntu@${instanceAddress} << EOSSH
mkdir blender_project
tar -xzf blender_project.tar.gz --directory ./blender_project
rm blender_project.tar.gz
cd blender_project

# see EQ-189 don't > /dev/null
echo Executing the render job
blender -b -noaudio ${blendFile} -P ./configure.py -o ~/out/ -F PNG -x 1 ${blenderOptions}
EOSSH
if [[ $? -ne 0 ]]; then
    echo Unexpected failure. Aborting ...
    cleanUp $instanceId
    exit 1
fi

# Save results of the finished render and clean up
echo -e "\nSaving final results to ${outPath}"
rsync -aze "ssh -i ${keyFile}" \
    ubuntu@${instanceAddress}:~/out/ \
    ${outPath} &> /dev/null

cleanUp ${instanceId}

kill %1 #kill background sync

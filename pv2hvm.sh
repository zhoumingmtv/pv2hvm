#!/usr/bin/env bash

# Usage: ./pv2hvm.sh <source_instance_id [name_of_log]
#  Parameters:
#    source_instance_id - instance id of the instance that to be converted
#  Options:
#    name_of_log - can be set to the name of the instance, set to default if not specified

# Warning:
# the converted hvm instance is a clone of the source instance at the time when the script runs,
# to be more exact, at the time when source instance AMI is created, any changes after that will be lost

# the script is to convert a paravirtual instance to a hvm one, it should run on a hvm instance as a 'working instance'
# I have created one 'working instance' called pv2hvm-working-1.vpc3 in 10gen-noc account
# the script does the conversions in following steps:
#     1 check whether all required tools are installed on the 'working instance'
#     2 create AMI of source instance (if source instance is running it'll be rebooted)
#     3 create a new volume (source root volume) from the AMI
#     4 attach the new source root volume to the 'working instance'
#     5 on the source root volume, check if grub exists, fsck check and resize
#     6 create a new volume (destination root volume) of the same size of source root volume
#     7 attach the new destination root volume to the 'working instance'
#     8 partition destination root volume
#     9 copy source to destination root volume with dd
#     10 resize destination root volume to the original size
#     11 on the destination root volunme, install grub, fix grub config file and fstab
#     12 create snapshot of the destination root volunme, and create block device mapping file
#     13 copy additional volumes snapshots from the source instance if any, and update block device mapping file
#     14 register an AMI from the snapshot, this is the AMI you can launch the migrated hvm instance from, and it'll be a clone of the source instance at the point of the time
#     15 cleanup - deregister source AMI, delete snapshots, delete volumes


az="us-east-1d"
region="us-east-1"
sysroot="/mnt"
logdir="/var/log/pv2hvm"
srcinstance="$1"
logfile="$logdir/${2:-default}.log"

LOGGING(){
  if [[ "$1" == "-n" ]]; then
    shift
    echo -ne "$(date "+%Y-%m-%d %H:%M:%S") $@" >>$logfile
  else
    echo -e "$(date "+%Y-%m-%d %H:%M:%S") $@" >>$logfile
  fi
}

IN_PROGRESS(){
  echo -ne "." >>$logfile
  sleep 5
}


CHECK_AWSCLI(){
  if aws --version >/dev/null 2>&1; then
    LOGGING "awscli installed at $(which aws)"
  else
    LOGGING "awscli not installed"
    exit 1
  fi
}

CHECK_JQ(){
  if which jq >/dev/null 2>&1; then
    LOGGING "jq installed"
  else
    LOGGING "installing jq.."
    sudo yum install jq
    if ! which jq >/dev/null 2>&1; then
      LOGGING "failed to install jq"
      exit 1
    fi
  fi
}

CHECK_PARTED(){
  if which parted >/dev/null 2>&1; then
    LOGGING "parted installed"
  else
    LOGGING "installing parted"
    sudo yum install parted
    if ! which parted >/dev/null 2>&1; then
      LOGGING "failed to install parted"
      exit 1
    fi
  fi
}

API_CALL(){
  api_call_result="RateLimit"
  while [[ "$api_call_result" =~ "RateLimit" ]]; do
    export api_call_result="$(aws --output json --region $region $@ 2>&1)"
    if [[ "$api_call_result" =~ "RateLimit" ]]; then
      local waittime="$(( ( RANDOM % 10 )  + 5 ))"
      LOGGING "current API call has been rate limited, waiting $waittime seconds to try again.";
      sleep $waittime
    fi
  done
}

CHECK_CRED(){
  workinginstanceid="$1"
  if [[ -f $HOME/.aws/config ]]; then
    API_CALL ec2 describe-instances --instance-ids $workinginstanceid
    if [[ "$api_call_result" =~ "UnauthorizedOperation" ]] || [[ "$api_call_result" =~ "AuthFailure" ]]; then
      LOGGING "failed API call describe-instances of the current working instance, invalid credentials"
      return 1
    fi
  else
    LOGGING "credential file not found"
    return 1
  fi
}

DESCRIBE_VOLUMES(){
  verb="$1"
  volumeid="$2"
  completestate="$3"
  pendingstate="$4"

  query_attachment_state=".Volumes[].Attachments[].State"
  query_state=".Volumes[].State"
  check_complete="false"

  while [ "$check_complete" != "true" ]; do
    API_CALL ec2 describe-volumes --volume-ids $volumeid
    case "$verb" in
      attach )
        if [ "$(echo $api_call_result | jq -r "$query_attachment_state")" == "$completestate" ]; then
          check_complete="true"
          echo "complete" >>$logfile
        elif [ "$(echo $api_call_result | jq -r "$query_attachment_state")" == "$pendingstate" ]; then
          IN_PROGRESS
        else
          echo -e "\nfailed" >>$logfile
          return 1
        fi
        ;;

      detach )
        if [ "$(echo $api_call_result | jq -r "$query_state")" == "$completestate" ]; then
          check_complete="true"
          echo "complete" >>$logfile
        elif [ "$(echo $api_call_result | jq -r "$query_attachment_state")" == "$pendingstate" ]; then
          IN_PROGRESS
        elif [ "$(echo $api_call_result | jq -r "$query_attachment_state")" == "busy" ]; then
          echo "device busy, try force detach" >>$logfile
          return 1
        else
          echo -e "\nfailed" >>$logfile
          return 1
        fi
        ;;

      create )
        if [ "$(echo $api_call_result | jq -r "$query_state")" == "$completestate" ]; then
          check_complete="true"
          echo "complete" >>$logfile
        elif [ "$(echo $api_call_result | jq -r "$query_state")" == "$pendingstate" ]; then
          IN_PROGRESS
        else
          echo -e "\nfailed" >>$logfile
          return 1
        fi
        ;;

      *)
        echo "specify a verb attach|detach|create for the function" >>$logfile
        ;;
    esac
  done
}

DESCRIBE_IMAGES(){
  imageid="$1"
  check_complete="false"
  while [ "$check_complete" != "true" ]; do
    API_CALL ec2 describe-images --image-ids $imageid
    if [ "$(echo $api_call_result | jq -r '.Images[].State')" == "available" ]; then
      check_complete="true"
      echo "complete" >>$logfile
    elif [ "$(echo $api_call_result | jq -r '.Images[].State')" == "pending" ]; then
      IN_PROGRESS
    else
      echo -e "\nfailed - reason: \n$(echo $api_call_result | jq -r '.Images[].StateReason.Message')" >>$logfile
      return 1
    fi
  done
}

DESCRIBE_SNAPSHOTS(){
  snapshotid="$1"
  check_complete="false"
  while [ "$check_complete" != "true" ]; do
    API_CALL ec2 describe-snapshots --snapshot-ids $snapshotid
    if [ "$(echo $api_call_result | jq -r '.Snapshots[].State')" == "completed" ]; then
      check_complete="true"
      echo "complete" >>$logfile
    elif [ "$(echo $api_call_result | jq -r '.Snapshots[].State')" == "pending" ]; then
      IN_PROGRESS
    else
      echo -e "failed - reason: \n$(echo $api_call_result | jq -r '.Snapshots[].StateReason.Message')" >>$logfile
      return 1
    fi
  done
}

DELETE_SNAPSHOT(){
  snapshotid="$1"
  if [ -z "$snapshotid" ]; then
    LOGGING "DELETE_SNAPSHOTS(), snapshot id empty or not defined"
    return 1
  fi
  API_CALL ec2 delete-snapshot --snapshot-id $snapshotid
  LOGGING "deleting snapshot $snapshotid.."
  echo "$api_call_result" >>$logfile
}

DEREGISTER_AMI(){
  amiid="$1"
  if [ -z "$amiid" ]; then
    LOGGING "DEREGISTER_AMI(), ami id empty or not defined"
    return 1
  fi
  API_CALL ec2 deregister-image --image-id $amiid
  LOGGING "deregistering ami $amiid"
  echo "$api_call_result" >>$logfile
}

DELETE_SOURCE_SNAPSHOTS(){
  if [ "$srcvolumecount" -eq 1 ]; then
    DELETE_SNAPSHOT "${srcvolumearr['root snap']}"
  elif [ "$srcvolumecount" -gt 1 ]; then
    for j in $(seq 0 i-1); do
      DELETE_SNAPSHOT "${srcvolumearr['vol${j} snap']}"
    done
  else
    LOGGING "source instance volume count is 0"
  fi
}

DETACH_ROOT_VOLUME(){
  volumeid="$1"
  LOGGING "umounting $sysroot"
  umount -v $sysroot 2>>$logfile 1>/dev/null
  if [ -n "$volumeid" ]; then
    API_CALL ec2 detach-volume --volume-id $volumeid
    LOGGING -n "detaching volume $volumeid.."
    DESCRIBE_VOLUMES "detach" "$volumeid" "available" "detaching"
  fi
}

DELETE_ROOT_VOLUME(){
  volumeid="$1"
  if [ -n "$volumeid" ]; then
    API_CALL ec2 delete-volume --volume-id $volumeid
    LOGGING -n "deleting volume $volumeid.."
    echo "$api_call_result" >>$logfile
  fi
}

CLEANUP(){
  LOGGING "*****cleanup*****"
  DEREGISTER_AMI "$tempami"
  DELETE_SOURCE_SNAPSHOTS
  DETACH_ROOT_VOLUME "$srcrootvolume"
  DETACH_ROOT_VOLUME "$dstrootvolume"
  DELETE_ROOT_VOLUME "$srcrootvolume"
  DELETE_ROOT_VOLUME "$dstrootvolume"
}



if [ -z "$1" ]; then
  echo -e "Usage: $0 <instance id> [log name]\n" | tee -a $logfile
  exit 1
fi


# prerequisite check for the working instance
LOGGING "prerequisite check for the working instance"
CHECK_AWSCLI
CHECK_JQ
CHECK_PARTED
workinginstanceid=$(curl http://169.254.169.254/latest/meta-data/instance-id)
if ! CHECK_CRED "$workinginstanceid"; then
  exit 1
fi


# sanity check of source instance, save source instance data
API_CALL ec2 describe-instances --instance-ids $srcinstance
LOGGING "sanity check of source instance $srcinstance"
if [[ "$api_call_result" =~ "InvalidInstanceID" ]]; then
  LOGGING "invalid source instance"
  exit 1
fi
srcinstancedata=$api_call_result

if [ "$(echo $srcinstancedata | jq -r '.Reservations[].Instances[].VirtualizationType')" == "hvm" ]; then
  LOGGING "source instance is already a hvm instance"
  exit 1
fi
if [ "$(echo $srcinstancedata | jq -r '.Reservations[].Instances[].ProductCodes[].ProductCodeType')" == "marketplace" ]; then
  LOGGING "source instance is a market place instance"
  exit 1
fi


# create source ami
if [ "$(echo $srcinstancedata | jq -r '.Reservations[].Instances[].State.Name')" != "stopped" ]; then
  LOGGING "source instance is running, will be rebooted before creating AMI"
fi
sleep 5
API_CALL ec2 create-image --instance-id $srcinstance --name temp-${srcinstance} --description temp_ami_from_source_${srcinstance} --reboot
tempami=$(echo $api_call_result | jq -r '.ImageId')
LOGGING -n "creating source AMI $tempami.."
if ! DESCRIBE_IMAGES "$tempami"; then
  echo "$api_call_result" >>$logfile
  exit 1
fi
srcimagedata=$api_call_result


# create source volumes array
declare -A srcvolumearr
srcvolumedata=$(echo $srcimagedata | jq -r '.Images[].BlockDeviceMappings[] | .DeviceName, .Ebs.SnapshotId, .Ebs.VolumeSize, .Ebs.VolumeType, .Ebs.Iops' | tr '\n' ' ' | sed 's/\(\/d.*\) \(\/d.*\)/\1\n\2/')
i=0
srcvolumecount=0
while IFS=$'\n' read line; do
  srcvolumedev="$(echo "$line" | awk '{print $1}')"
  srcvolumesnap="$(echo "$line" | awk '{print $2}')"
  srcvolumesize="$(echo "$line" | awk '{print $3}')"
  srcvolumetype="$(echo "$line" | awk '{print $4}')"
  srcvolumeiops="$(echo "$line" | awk '{print $5}')"
  if [[ "$srcvolumedev" =~ "sda" ]] || [[ "$srcvolumedev" =~ "xvde" ]]; then
    srcvolumearr["root device"]="$srcvolumedev"
    srcvolumearr["root snap"]="$srcvolumesnap"
    srcvolumearr["root size"]="$srcvolumesize"
    srcvolumearr["root type"]="$srcvolumetype"
    srcvolumearr["root iops"]="$srcvolumeiops"
    srcvolumecount=1
  else
    srcvolumearr["vol${i} device"]="$srcvolumedev"
    srcvolumearr["vol${i} snap"]="$srcvolumesnap"
    srcvolumearr["vol${i} size"]="$srcvolumesize"
    srcvolumearr["vol${i} type"]="$srcvolumetype"
    srcvolumearr["vol${i} iops"]="$srcvolumeiops"
    ((i++))
    ((srcvolumecount++))
  fi
done <<<"$srcvolumedata"

if [ "${#srcvolumearr[@]}" -eq 0 ]; then
  LOGGING "source volumes empty, manual cleanup needed"
  exit 1
fi
LOGGING "source volumes/devices: ${srcvolumearr[@]}"


# create source root volume
if [ "${srcvolumearr['root type']}" == "io1" ]; then
  API_CALL ec2 create-volume --snapshot-id "${srcvolumearr["root snap"]}" --availability-zone $az --size "${srcvolumearr["root size"]}" --volume-type "${srcvolumearr["root type"]}" --iops ${srcvolumearr["root iops"]}
else
  API_CALL ec2 create-volume --snapshot-id "${srcvolumearr["root snap"]}" --availability-zone $az --size "${srcvolumearr["root size"]}" --volume-type "${srcvolumearr["root type"]}"
fi
srcrootvolume=$(echo $api_call_result | jq -r '.VolumeId')
LOGGING -n "creating source root volume $srcrootvolume.."
if ! DESCRIBE_VOLUMES "create" "$srcrootvolume" "available" "creating"; then
  echo "$api_call_result" >>$logfile
  DEREGISTER_AMI "$tempami"
  DELETE_SOURCE_SNAPSHOTS
  exit 1
fi


# attach source root volume to the working instance
srcdev="/dev/sdp"
srcdevletter=${srcdev##*d}
API_CALL ec2 describe-instances --instance-ids $workinginstanceid
workinginstancedata=$api_call_result
devmapping=$(echo $workinginstancedata | jq -r '.Reservations[].Instances[].BlockDeviceMappings[].DeviceName')
if [[ "$devmapping" =~ "/dev/sd${srcdevletter}" || "$devmapping" =~ "/dev/xvd${srcdevletter}" ]]; then
  LOGGING "source device $srcdev is in use, specify another one"
  DEREGISTER_AMI "$tempami"
  DELETE_SOURCE_SNAPSHOTS
  DELETE_ROOT_VOLUME "$srcrootvolume"
  exit 1
else
  API_CALL ec2 attach-volume --volume-id $srcrootvolume --instance-id $workinginstanceid --device $srcdev
  LOGGING -n "attaching source root volume to the working instance.."
  if ! DESCRIBE_VOLUMES "attach" "$srcrootvolume" "attached" "attaching"; then
    echo "$api_call_result" >>$logfile
    DEREGISTER_AMI "$tempami"
    DELETE_SOURCE_SNAPSHOTS
    DELETE_ROOT_VOLUME "$srcrootvolume"
    exit 1
  fi
fi


# get source device name
check_src="false"
for i in "xvd${srcdevletter}1" "sd${srcdevletter}1"; do
  if mount -v "/dev/${i}" "$sysroot" >/dev/null 2>&1; then
    export src="/dev/${i}"
    check_src="true"
    LOGGING "source root volume is attached at $src"
    break
  fi
done
if [ "$check_src" == "false" ]; then
  LOGGING "getting source device name failed"
  DEREGISTER_AMI "$tempami"
  DELETE_SOURCE_SNAPSHOTS
  DETACH_ROOT_VOLUME "$srcrootvolume"
  DELETE_ROOT_VOLUME "$srcrootvolume"
  exit 1
fi


# check if grub installed on source root volume
LOGGING -n "checking grub 0.97 on source root volume.."
if (which $sysroot/sbin/grub || which $sysroot/usr/sbin/grub) >/dev/null 2>&1 && [[ "$(grub --version)" =~ "0.97" ]] >/dev/null 2>&1; then
  echo "complete" >>$logfile
else
  echo "no or wrong version of grub installed" >>$logfile
  DEREGISTER_AMI "$tempami"
  DELETE_SOURCE_SNAPSHOTS
  DETACH_ROOT_VOLUME "$srcrootvolume"
  DELETE_ROOT_VOLUME "$srcrootvolume"
  exit 1
fi

LOGGING "umounting $sysroot"
umount -v $sysroot 2>>$logfile 1>/dev/null


# fsck source root volume
LOGGING "fsck check source root volume"
e2fsck -vfp "$src" 1>/dev/null 2>>$logfile
if [ "$?" -eq 0 ]; then
    LOGGING "fsck OK, resizing source root volume"
    resize2fs -d 16 -M "$src" 2>>$logfile 1>>$logfile
else
    LOGGING "fsck failed, skip resizing"
    DEREGISTER_AMI "$tempami"
    DELETE_SOURCE_SNAPSHOTS
    DETACH_ROOT_VOLUME "$srcrootvolume"
    DELETE_ROOT_VOLUME "$srcrootvolume"
    exit 1
    # increment dstrootvolume size by 1 when fsck fails?
fi
dump=$(dumpe2fs -h "$src")
block_size=$(awk -F':[ \t]+' '/^Block size:/ {print $2}' <<<"$dump")
block_count=$(awk -F':[ \t]+' '/^Block count:/ {print $2}' <<<"$dump")
if [ -z "$block_size" ] || [ -z "$block_count" ]; then
  LOGGING "dumpe2fs source root volume failed"
  DEREGISTER_AMI "$tempami"
  DELETE_SOURCE_SNAPSHOTS
  DETACH_ROOT_VOLUME "$srcrootvolume"
  DELETE_ROOT_VOLUME "$srcrootvolume"
  exit 1
fi
LOGGING "dumpe2fs source root volume complete, block size: $block_size, block count: $block_count"


# create destination root volume
dstrootvolumesize="${srcvolumearr["root size"]}"
dstrootvolumetype="${srcvolumearr["root type"]}"
if [[ "$dstrootvolumetype" == "io1" ]]; then
    dstrootvolumeiops="${srcvolumearr["root iops"]}"
    API_CALL ec2 create-volume --availability-zone $az --size $dstrootvolumesize --volume-type $dstrootvolumetype --iops $dstrootvolumeiops
else
    API_CALL ec2 create-volume --availability-zone $az --size $dstrootvolumesize --volume-type $dstrootvolumetype
fi
dstrootvolume="$(echo $api_call_result | jq -r '.VolumeId')"
LOGGING -n "creating destination root volume $dstrootvolume.."
if ! DESCRIBE_VOLUMES "create" "$dstrootvolume" "available" "creating"; then
  echo "$api_call_result" >>$logfile
  DEREGISTER_AMI "$tempami"
  DELETE_SOURCE_SNAPSHOTS
  DETACH_ROOT_VOLUME "$srcrootvolume"
  DELETE_ROOT_VOLUME "$srcrootvolume"
  exit 1
fi


# attach destination root volume to the working instance
dstdev="/dev/sdh"
dstdevletter=${dstdev##*d}
API_CALL ec2 describe-instances --instance-ids $workinginstanceid
workinginstancedata=$api_call_result
devmapping=$(echo $workinginstancedata | jq -r '.Reservations[].Instances[].BlockDeviceMappings[].DeviceName')
if [[ "$devmapping" =~ "/dev/sd${dstdevletter}" || "$devmapping" =~ "/dev/xvd${dstdevletter}" ]]; then
  LOGGING "destination device $dstdev is in use, specify another one"
  DEREGISTER_AMI "$tempami"
  DELETE_SOURCE_SNAPSHOTS
  DETACH_ROOT_VOLUME "$srcrootvolume"
  DELETE_ROOT_VOLUME "$srcrootvolume"
  DELETE_ROOT_VOLUME "$dstrootvolume"
  exit 1
else
  API_CALL ec2 attach-volume --volume-id $dstrootvolume --instance-id $workinginstanceid --device $dstdev
  LOGGING -n "attaching destination root volume to the working instance.."
  if ! DESCRIBE_VOLUMES "attach" "$dstrootvolume" "attached" "attaching"; then
    echo "$api_call_result" >>$logfile
    DEREGISTER_AMI "$tempami"
    DELETE_SOURCE_SNAPSHOTS
    DETACH_ROOT_VOLUME "$srcrootvolume"
    DELETE_ROOT_VOLUME "$srcrootvolume"
    DELETE_ROOT_VOLUME "$dstrootvolume"
    exit 1
  fi
fi


# get destination device name
check_dst="false"
for i in "xvd${dstdevletter}" "sd${dstdevletter}"; do
  if [ "$(file -s /dev/${i})" == "/dev/${i}: data" ]; then
    export dst="/dev/${i}"
    check_dst="true"
    LOGGING "destination root volume is attached at $dst"
    break
  fi
done
if [ "$check_dst" == "false" ]; then
  LOGGING "getting destination device name failed"
  CLEANUP
  exit 1
fi


# partition destination device
LOGGING "partitioning destination device.."
parted $dst --script 'mklabel msdos mkpart primary 1M -1s print quit' >>$logfile 2>&1
partprobe $dst >>$logfile 2>&1
udevadm settle >>$logfile 2>&1


# copy source to destination device
dd if=$src of=${dst}1 bs=$block_size count=$block_count 2>>$logfile & pid=$!
LOGGING "cloning source root volume to destination root volume, issue 'kill -USR1 $pid' to print I/O statistics to the logfile"
while [ -d "/proc/$pid" ]; do
    sleep 5
done
if wait $pid; then
  LOGGING "disk clone completed"
else
  LOGGING "disk clone failed"
  CLEANUP
  exit 1
fi


# resize destination root volume
LOGGING "resizing destination root volume"
resize2fs -d 16 "${dst}1" 2>>$logfile 1>>$logfile


# install grub on destination root volume
LOGGING "installing grub on destination root volume.."
mount -v "${dst}1" "$sysroot" 1>/dev/null 2>>$logfile
cp -va "$dst" "${dst}1" "$sysroot/dev/" 1>/dev/null 2>>$logfile
rm -vf "$sysroot/boot/grub/*stage*" 1>/dev/null 2>>$logfile
find "$sysroot/usr" -type f -path "*grub*stage*" -exec cp -fv {} "$sysroot/boot/grub/" \;  1>/dev/null 2>>$logfile
rm -vf "$sysroot/boot/grub/device.map"  1>/dev/null 2>>$logfile
(cat <<EOF | chroot "$sysroot" grub --batch
device (hd0) $dst
root (hd0,0)
setup (hd0)
EOF
) >>$logfile 2>&1
echo -e "\n" >>$logfile
LOGGING "grub install finished"
rm -vf "${sysroot}${dst}" "${sysroot}${dst}1" 1>/dev/null 2>>$logfile


# fix grub conf and link menu.lst to grub.conf
LOGGING "fixing grub conf"
for grub in grub.conf menu.lst; do
  if [ -e "$sysroot/boot/grub/$grub" ]; then
    sed --follow-symlinks -i 's/(hd0)/(hd0,0)/' "$sysroot/boot/grub/$grub" > /dev/null 2>&1
    sed --follow-symlinks -i 's/root=\([^ ]*\)/root=LABEL=\//' "$sysroot/boot/grub/$grub" > /dev/null 2>&1
    sed --follow-symlinks -i 's/console*\([^ ]*\)//' "$sysroot/boot/grub/$grub" > /dev/null 2>&1
    if [[ ! $(grep -i "kernel" "$sysroot/boot/grub/$grub") =~ "console" ]]; then
        sed --follow-symlinks -i '/kernel/{s/$/ console\=ttyS0/}' "$sysroot/boot/grub/$grub" > /dev/null 2>&1
    fi
  fi
done

if [ -e "$sysroot/boot/grub/menu.lst" ] && [ ! -L "$sysroot/boot/grub/menu.lst" ]; then
  LOGGING "making menu.lst a symlink to grub.conf"
  (cat <<EOF | chroot "$sysroot" /bin/bash
  cd /boot/grub
  cp -va menu.lst grub.conf
  rm -vf menu.lst
  ln -s /boot/grub/grub.conf menu.lst
  chmod 600 grub.conf
EOF
) >>$logfile 2>&1
elif [ ! -e "$sysroot/boot/grub/menu.lst" ] && [ -e "$sysroot/boot/grub/grub.conf" ]; then
  LOGGING "creating menu.lst as a symlink to grub.conf"
  (cat <<EOF | chroot "$sysroot" /bin/bash
  cd /boot/grub
  ln -s /boot/grub/grub.conf menu.lst
EOF
) >>$logfile 2>&1
else
  LOGGING "menu.lst is a symlink to grub.conf, nothing to be done"
fi

if [ ! -s "$sysroot/boot/grub/grub.conf" ]; then
  LOGGING "grub conf file empty"
  CLEANUP
  exit 1
fi

LOGGING "grub conf file:"
cat "$sysroot/boot/grub/grub.conf" >>$logfile


# fix fstab
LOGGING "fixing fstab"
sed -i 's,^.*\ / ,LABEL=\/\ \ \/,' "$sysroot/etc/fstab" 2>>$logfile
LOGGING "fstab file:"
cat "$sysroot/etc/fstab" >>$logfile


# add label for destination root volume
LOGGING "labeling ${dst}1 to /"
e2label "${dst}1" / 2>>$logfile

LOGGING "umounting $sysroot"
umount -v $sysroot 2>>$logfile 1>/dev/null


# create snapshot of destination root volume, and create block device mapping file
mapping="/tmp/dst_block_device_mapping"
echo -e "[\n" > $mapping
API_CALL ec2 create-snapshot --volume-id $dstrootvolume --description hvm_converted_for_${srcinstance}_root
dstrootvolumesnap="$(echo $api_call_result | jq -r '.SnapshotId')"
LOGGING -n "creating snapshot $dstrootvolumesnap for destination root volume.."
if ! DESCRIBE_SNAPSHOTS "$dstrootvolumesnap"; then
  echo "$api_call_result" >>$logfile
  CLEANUP
  exit 1
fi
if [[ "${srcvolumearr["root type"]}" == "io1" ]]; then
  echo -e "  {\n    \"VirtualName\": \"ebs\",\n    \"DeviceName\": \"/dev/sda1\",\n    \"Ebs\": {\n           \"SnapshotId\": \"$dstrootvolumesnap\",\n           \"VolumeSize\": ${srcvolumearr["root size"]},\n           \"VolumeType\": \"${srcvolumearr["root type"]}\",\n           \"Iops\": ${srcvolumearr["root iops"]}\n    }\n  }," >> $mapping
else
  echo -e "  {\n    \"VirtualName\": \"ebs\",\n    \"DeviceName\": \"/dev/sda1\",\n    \"Ebs\": {\n           \"SnapshotId\": \"$dstrootvolumesnap\",\n           \"VolumeSize\": ${srcvolumearr["root size"]},\n           \"VolumeType\": \"${srcvolumearr["root type"]}\"\n    }\n  }," >> $mapping
fi


# copy any additional volumes snapshots from the source, and update block device mapping file
for i in $(seq 0 $(($srcvolumecount-2))); do
  API_CALL ec2 copy-snapshot --source-region $region --destination-region $region --source-snapshot-id "${srcvolumearr["vol${i} snap"]}" --description hvm_converted_for_${srcinstance}_vol${i}
  dstvolumesnap="$(echo $api_call_result | jq -r '.SnapshotId')"
  LOGGING -n "creating $dstvolumesnap from $srcvolumesnap.."
  if DESCRIBE_SNAPSHOTS "$dstvolumesnap"; then
    if [[ "${srcvolumearr["vol${i} type"]}" == "io1" ]]; then
      echo -e "  {\n    \"VirtualName\": \"ebs\",\n    \"DeviceName\": \"${srcvolumearr["vol${i} device"]}\",\n    \"Ebs\": {\n           \"SnapshotId\": \"$dstvolumesnap\",\n           \"VolumeSize\": ${srcvolumearr["vol${i} size"]},\n           \"VolumeType\": \"${srcvolumearr["vol${i} type"]}\",\n           \"Iops\": ${srcvolumearr["vol${i} iops"]}\n    }\n  }," >> $mapping
    else
      echo -e "  {\n    \"VirtualName\": \"ebs\",\n    \"DeviceName\": \"${srcvolumearr["vol${i} device"]}\",\n    \"Ebs\": {\n           \"SnapshotId\": \"$dstvolumesnap\",\n           \"VolumeSize\": ${srcvolumearr["vol${i} size"]},\n           \"VolumeType\": \"${srcvolumearr["vol${i} type"]}\"\n    }\n  }," >> $mapping
    fi
  else
    echo "$api_call_result" >>$logfile
    LOGGING "manual cleanup needed"
  fi
done

sed -i '$d' $mapping
echo -e "  }\n]" >> $mapping

LOGGING "destination device mapping file:"
cat "$mapping" >>$logfile


# register hvm ami
API_CALL ec2 register-image --name hvm_converted_${srcinstance} --description hvm_converted_from_${srcinstance} --architecture x86_64 --root-device-name /dev/sda1 --virtualization-type hvm --block-device-mappings file://$mapping
hvmami="$(echo $api_call_result | jq -r '.ImageId')"
LOGGING -n "registering hvm ami $hvmami for source instance ${srcinstance}.."
if ! DESCRIBE_IMAGES "$hvmami"; then
  echo "$api_call_result" >>$logfile
  DEREGISTER_AMI "$tempami"
  DELETE_SOURCE_SNAPSHOTS
  DETACH_ROOT_VOLUME "$srcrootvolume"
  DELETE_ROOT_VOLUME "$srcrootvolume"
  exit 1
fi


# final cleanup
CLEANUP

#!/bin/sh

export LD_LIBRARY_PATH=/system/workdir/lib:/lib/:$LD_LIBRARY_PATH
TOP=${0%/*}
cd $TOP
TOP=`pwd`

GPIOTOOL=./gpiotool_MT7628

MD5FILE=md5.txt
LAYOUTFILE=layout

DIFF="./busybox diff"
CUT="./busybox cut"
WC="./busybox wc"
MD5SUM="./busybox md5sum"
DD="./busybox dd"
CAT="./busybox cat"
GREP="./busybox grep"
USLEEP="./busybox usleep"
XARGS="./busybox xargs"
PRINTF="./busybox printf"
EXPR="./busybox expr"
HEAD="./busybox head"
STAT="./busybox stat"
TR="./busybox tr"
TEE="./busybox tee -a"
RM="./busybox rm -rf"
REG="/tmp/reg"
MTD_WRITE="/tmp/mtd_write"

# all partion need update
ALL_PARTION_NAME="uboot uImage backup user2"

PARTION_OFFSET=0x50000
PARTION_SIZE=0x10000

IMAGE_MD5="abcd"
IMAGE_NAME="kernel"
IMAGE_SIZE="10000"

PARTION_MD5="abcd"
LOGFILE="$TOP/usblog.log"


## SDA(1) SCL(2) DCD_N(12) RIN(14)
## RED LED (DCD_N)
LED1=14
# GPIO12 connect to GPIO10 on Test board
LED1A=0

## Blue LED ( RIN)
LED2=16
# GPIO14 connect to GPIO40 on Test board
LED2A=18



# LED1 OFF, LED2 ON
show_status_burning()
{
	echo "burning..." | $TEE $LOGFILE
	pkill gpiotool
	$GPIOTOOL level 0 $LED1 $LED1A
	$GPIOTOOL level 1 $LED2
	$GPIOTOOL level 1 $LED2A
}

# LED1 ON, LED2 Blink slowly
show_status_update_ok()
{
	echo "update ok..." | $TEE $LOGFILE
	sync
	pkill gpiotool
	$GPIOTOOL level 1 $LED1 $LED1A
	while [ 1 ]; do
		$GPIOTOOL level 1 $LED2
		$GPIOTOOL level 1 $LED2A
		$USLEEP 1000000
		$GPIOTOOL level 0 $LED2
		$GPIOTOOL level 0 $LED2A
		$USLEEP 1000000
	done
}

# LED1 blink fast, LED2 blink fast
show_status_update_fail()
{
	echo "update fail" | $TEE $LOGFILE
	sync
	pkill gpiotool
	while [ 1 ]; do
		$GPIOTOOL level 1 $LED1 $LED1A
		$GPIOTOOL level 1 $LED2
		$GPIOTOOL level 1 $LED2A
		$USLEEP 100000
		$GPIOTOOL level 0 $LED1 $LED1A
		$GPIOTOOL level 0 $LED2
		$GPIOTOOL level 0 $LED2A
		$USLEEP 100000
	done
}

## set i2c sda/scl to gpio mode
set_i2c_to_gpio_mode()
{
	$REG s 0
	gpiomode=`$REG p 60`
	t=`$PRINTF "%d" $gpiomode`
	let "t=$t|1"
	t=`$PRINTF "%x" $t`
	t="0x$t"
	echo "gpio mode from $gpiomode to $t"
	$REG w 60 $t
}

## set uartf to gpio mode
set_uartf_to_gpio_mode()
{
	$REG s 0
	gpiomode=`$REG p 60`
	t=`$PRINTF "%d" $gpiomode`
	let "t=$t|28"
	t=`$PRINTF "%x" $t`
	t="0x$t"
	echo "gpio mode from $gpiomode to $t"
	$REG w 60 $t
}

## set jtag to gpio mode (gpio17-21)
set_jtag_to_gpio_mode()
{
	$REG s 0
	gpiomode=`$REG p 60`
	t=`$PRINTF "%d" $gpiomode`
	let "t=$t|65536"
	t=`$PRINTF "%x" $t`
	t="0x$t"
	echo "gpio mode from $gpiomode to $t"
	$REG w 60 $t
}


init_gpio()
{
	#set_i2c_to_gpio_mode
	set_uartf_to_gpio_mode
	set_jtag_to_gpio_mode
}

# PARTION_OFFSET save the offset of 0 address
# PARTION_SIZE save partion size
# return 0 for success, return 1 has error
get_partion_info()
{
	local PARTION_NAME=$1
	
	[ "$PARTION_NAME" == "uImage" ] && PARTION_NAME="kernel"
	PARTION_OFFSET=`$CAT $LAYOUTFILE  | $GREP $PARTION_NAME  | $CUT -d':' -f1`
	
	# if cann't get layout for uboot and backup, use default layout,
	# because the latest version have not uboot and backup layout for online update
	if [ "$PARTION_OFFSET" == "" ]; then
		if [ "$PARTION_NAME" == "uboot" ]; then
			echo "cann't get $PARTION_NAME in layout, use default" | $TEE $LOGFILE
			PARTION_OFFSET=`$PRINTF %d 0x00000`
			PARTION_SIZE=`$PRINTF %d 0x30000`
			return 0
		elif [ "$PARTION_NAME" == "backup" ]; then
			echo "cann't get $PARTION_NAME in layout, use default" | $TEE $LOGFILE
			PARTION_OFFSET=`$PRINTF %d 0x50000`
			PARTION_SIZE=`$PRINTF %d 0x20000`
			return 0
		else
			echo "cann't get $PARTION_NAME in layout" | $TEE $LOGFILE
			return 1
		fi
	fi
	
	PARTION_OFFSET=`$PRINTF %d 0x$PARTION_OFFSET`
	PARTION_SIZE=`$CAT $LAYOUTFILE  | $GREP $PARTION_NAME  | $CUT -d':' -f2`
	if [ "$PARTION_SIZE" != "" ]; then
		PARTION_SIZE=`$PRINTF %d 0x$PARTION_SIZE`
	fi
	
	return 0
}

# IMAGE_MD5 save the md5 from md5 file
# IMAGE_NAME save the image name from md5 file
# IMAGE_SIZE save the image size cacluated by stat command
# return 0 for success, return 1 has error
get_image_info()
{
	local PARTION_NAME=$1
	IMAGE_MD5=`$CAT $MD5FILE  | $GREP $PARTION_NAME  | $CUT -d' ' -f1`
	IMAGE_NAME=`$CAT $MD5FILE  | $GREP $PARTION_NAME  | $CUT -d' ' -f3`
	IMAGE_SIZE=`$STAT -c %s $IMAGE_NAME | $TR -d '\n'`
	
	[ "IMAGE_NAME" == "" ] && return 1
	
	return 0
}

# return 1 is file not exist
# return 0 is the file exist
check_image_exist()
{
	local PARTION_NAME=$1
	local FILE_NAME
	
	FILE_NAME=`$CAT $MD5FILE  | $GREP $PARTION_NAME  | $CUT -d' ' -f3`
	
	[ "$FILE_NAME" == "" ] && return 1
	[ -f $FILE_NAME ] || return 1

	return 0
}

# dump the data from flash with PARTION_OFFSET and IMAGE_SIZE
# cacluate the md5 by data dumped from flash
# diff with the md5 from md5 file
# return 0: md5 is same
# return 1: md5 is not correct
check_md5_diff()
{
	local PARTION_NAME=$1
	local SEEK_COUNT
	local IMAGE_COUNT
	
	IMAGE_COUNT=`$EXPR $IMAGE_SIZE / 65536`
	IMAGE_COUNT=`$EXPR $IMAGE_COUNT + 1`
	SEEK_COUNT=`$EXPR $PARTION_OFFSET / 65536`				#must 64K align
	
	$RM /tmp/image.tmp
	$RM /tmp/image
	$DD if=/dev/mtd0 skip=$SEEK_COUNT of=/tmp/image.tmp bs=64K count=$IMAGE_COUNT
	
	$HEAD -c $IMAGE_SIZE /tmp/image.tmp > /tmp/image
	PARTION_MD5=`$MD5SUM /tmp/image | $CUT -d' ' -f1`
	if [ "$PARTION_MD5" == "$IMAGE_MD5" ]; then
		$RM /tmp/image.tmp
		$RM /tmp/image
		return 0
	else
		$RM /tmp/image.tmp
		$RM /tmp/image
		return 1
	fi
}

# save the image file to flash with PARTION_OFFSET and IMAGE_SIZE
update()
{
	local PARTION_NAME=$1
	local SEEK_COUNT
	local IMAGE_COUNT
	
	IMAGE_COUNT=`$EXPR $IMAGE_SIZE / 65536`
	IMAGE_COUNT=`$EXPR $IMAGE_COUNT + 1`
	SEEK_COUNT=`$EXPR $PARTION_OFFSET / 65536`
	
	$DD if=$IMAGE_NAME of=/dev/mtdblock0 seek=$SEEK_COUNT bs=64K count=$IMAGE_COUNT conv=fsync | $TEE $LOGFILE
	return $?
}

# check all image in storage is broken
# return 1 is have some image broken
# return 0 is all image ok
check_image_broken()
{
	local TMP_MD5
	for PARTION_NAME in $ALL_PARTION_NAME; do
		check_image_exist $PARTION_NAME
		[ $? == 1 ] && continue
		get_image_info $PARTION_NAME
		TMP_MD5=`$MD5SUM $IMAGE_NAME | $CUT -d' ' -f1`
		if [ "$TMP_MD5" != "$IMAGE_MD5" ]; then
			echo "$IMAGE_NAME is broken" | $TEE $LOGFILE
			return 1
		fi
	done
	
	return 0
}

# restore device to factory
restore_factory()
{
	nvram_set 2860 WebInit 0
	$MTD_WRITE erase /dev/mtd8 | $TEE $LOGFILE
	$MTD_WRITE erase /dev/mtd9 | $TEE $LOGFILE
}

# write ssid and project name
set_project_information()
{
	#local SSID="LinkPlayA31"
	#local PROJECT="WiFiDemo"
	
	#$GPIOTOOL PrivSet 2 $SSID
	#[ $? == 1 ] && return 1
	#$GPIOTOOL PrivSet 3 $PROJECT
	#[ $? == 1 ] && return 1
	
	return 0
}

prepare()
{
	cp -rf /bin/reg $REG
	cp -f /bin/mtd_write $MTD_WRITE
	echo 0 > /proc/sys/kernel/printk
	killall mdevnotify

	#free memory
	pkill rootApp
	pkill iperf
	echo 3 > /proc/sys/vm/drop_caches
	telnetd &
	
	init_gpio
}

main()
{
	local SUCCESS=0
	local PARTION_NAME
	local RESULT
	
	# slee 3 seconds, wait rootApp has cleaned
	sleep 3
	
	umount -l /dev/mtdblock8
	umount -l /dev/mtdblock9
	
	restore_factory
	
	set_project_information
	if [ $? == 1 ]; then
		echo "write ssid and project information error" | $TEE $LOGFILE
		return 1
	fi
	
	check_image_broken
	if [ $? == 1 ]; then
		echo "image broken, don't update" | $TEE $LOGFILE
		return 1
	fi

	for PARTION_NAME in $ALL_PARTION_NAME; do
		echo "======$PARTION_NAME======" | $TEE $LOGFILE
		check_image_exist $PARTION_NAME
		if [ $? == 0 ]; then
			echo "found image for $PARTION_NAME" | $TEE $LOGFILE
			
			#get partion info
			get_partion_info $PARTION_NAME
			RESULT=$?
			echo "$PARTION_NAME: offset=$PARTION_OFFSET size=$PARTION_SIZE" | $TEE $LOGFILE
			[ $RESULT == 1 ] && continue
			
			#get image info
			get_image_info $PARTION_NAME
			RESULT=$?
			echo "$IMAGE_NAME: md5=$IMAGE_MD5 size=$IMAGE_SIZE" | $TEE $LOGFILE
			[ $RESULT == 1 ] && continue
			
			#check md5
			check_md5_diff $PARTION_NAME
			if [ $? == 1 ]; then
				#start update
				echo "$PARTION_NAME start update" | $TEE $LOGFILE
				
				update $PARTION_NAME
				SUCCESS=$?
				sync
				
				if [ $SUCCESS != 0 ]; then
					echo "$PARTION_NAME update failed" | $TEE $LOGFILE
					break
				fi
				
				echo "$PARTION_NAME update finish" | $TEE $LOGFILE
				check_md5_diff $PARTION_NAME
				if [ $? == 1 ]; then
					echo "$PARTION_NAME md5 checksum fail, $PARTION_MD5" | $TEE $LOGFILE
					SUCCESS=1
					break
				fi
			else
				echo "$PARTION_NAME checksum is correct, ignore" | $TEE $LOGFILE
			fi
		fi
	done
	
	return $SUCCESS
}


prepare

$RM $LOGFILE
echo "===========Start===========" | $TEE $LOGFILE
cat /proc/uptime | $TEE $LOGFILE
echo "===========================" | $TEE $LOGFILE

show_status_burning

main
RESULT=$?

echo "===========DONE============" | $TEE $LOGFILE
cat /proc/uptime | $TEE $LOGFILE
echo "===========================" | $TEE $LOGFILE
sync
[ $RESULT == 0 ] && show_status_update_ok
[ $RESULT == 1 ] && show_status_update_fail

while [ 1 ]; do
	echo "sleep forever, result: $resultstr" | $TEE $LOGFILE
	sleep 10
done


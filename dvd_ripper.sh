#! /usr/bin/env bash

# set -x

temp_dir="/Users/bamersbach/Desktop/MakeMKV"
targetServer="bamersbach@server.mac-anu.com"
sshKey="/Users/bamersbach/.ssh/id_rsa"
targetDir="/Volumes/Data_RAID/DVD Rips"

source_device=""
volume_name=""
outfile=""
error=""

termHeight=""
termWidth=""
scrollHeight=""
progressPID=""

function initTerm {
	termHeight=$(tput lines)
	termWidth=$(tput cols)
	scrollHeight=$(($termHeight - 2))
	printf "\e[?1049h"				# Enable alternate screen buffer
	printf '\e[1;'$scrollHeight'r'	# Set scroll region
}

function deinitTerm {
	printf "\e[?25h"				# Show cursor
	printf '\e[49m\e[39m'			# Restore default colors
	printf '\e[?1049l'				# Disable alternate screen buffer
# 	printf '\e[1;'$termHeight'r'	# Reset scroll region
}

function exitScript {
	# Uh-oh gotta go
	[[ $(pgrep makemkvcon) ]] && pkill makemkvcon
	[[ $(ps $progressPID) ]] && kill $progressPID &>/dev/null
	deinitTerm
	
	[[ -z "${error}" ]] || printf '\e[31m\e[1mFatal: %s\e[0m\n' "${error}"
}

function setup {
    local diskList="$(diskutil list external physical)"
    [[ -z $diskList ]] && error="No disc" && exit 1
    source_device="$(grep -e 'disk\d$' <<< "${diskList}"| head -n 1 | \
    	awk '{print $NF}')"
	echo "${diskList}"
	# This requires bash 4.x to work
    read -e -p "Use which disk? " -i "$source_device" source_device
}

function ripConfig {
    # Using volume name as the name of the output .iso file. Piping through 
    # xargs trims leading/trailing whitespace
    volume_name="$(\
        diskutil info /dev/disk4 \
        | grep "Volume Name" \
        | xargs \
        | cut -d ' ' -f 3-)"
    outfile="${temp_dir}/$volume_name.iso"
    discId="$(makemkvcon -r info disc | grep ${source_device} | \
    	cut -d ',' -f 1 | tail -c 2)"

	# Confirming settings
    printf -- "\nSource device: ${source_device}\n"
    printf -- "Output file: ${outfile}\n"
    printf -- "Disc ID: ${discId}\n"
    
    # Get output file name
    local response=""
    read -t 15 -p "Press return to continue or n to rename file: " response
    if [[ "$response" = "n" ]] ; then
    	renameOutput
    fi
    
    # Does that file already exist? We don't want to clobber something.
	local safePath=$(echo "$targetDir"/"$volume_name.iso" | sed -e 's/ /\\ /g')
    if ssh -i "$sshKey" "$targetServer" "stat $safePath" &>/dev/null ; then
    	printf "\nFile exists on target, choose something else\n" && renameOutput
	fi
}

function progress {
	local messagesLength=""
	local line=""
	
	sleep 1				# Take a beat for makemkvcon to get going and start logging
	printf "\e[?25l"	# Hide cursor
	
	while true ; do
		# Make sure the terminal hasn't changed on us
		[[ $(tput lines) != "${termHeight}" ]] && initTerm
		
		# See if we have a new message from makemkvcon and print it
		local newLine="$(tail -n 1 "${temp_dir}/messages.txt")"
		if [[ "$newLine" != "$line" ]] ; then
			line="${newLine}"
			printf '%s\n' "$line"
		fi				
		
		# Do a bunch of ANSI terminal stuff and show the current progress
		printf "\e[s"							# Save cursor position
		
		printf '\e['$termHeight';0H'			# Move to bottom line
		printf '\e[0;30m\e[102m'				# Black text on Green background
		tail -n 1 "${temp_dir}/progress.txt"
		sleep 1
		printf '\e[49m\e[39m'					# Restore default colors
		printf "\e[2K"							# Erase line
		printf "\e[u"							# Restore cursor position
		
		[[ $(pgrep makemkvcon) ]] || break		# Bail if makemkvcon is no longer running
	done
	
	printf "\e[?25h"	# Show cursor
	
	return 0
}

function rip {
	ripConfig
	
    printf -- "\nRipping $volume_name...\n"
    local starttime="$(date "+%s")"
    diskutil unmount /dev/$source_device
    progress &
	progressPID=$!
	
	# If we have trouble with a disc, we can fall back to dd
	# dd if=/dev/"${source_device}" of="${outfile}"  \
# 		conv=sync,noerror \
# 		bs=1M \
# 		status=progress \
# 		speed=2097152
	
    makemkvcon \
    	--decrypt \
		--messages="${temp_dir}/messages.txt" \
		--progress="${temp_dir}/progress.txt" \
		--cache=128 \
    	backup disc:"$discId" "$outfile"
#     	| grep -v "BUP"
    
	sleep 1			# Take a beat so progress function can clean up
    progressPID=""	# Clear this so we don't accidentally kill some other process
    
    local endtime="$(date "+%s")"
    local difftime=$(("$endtime"-"$starttime"))
    difftime=$(bc <<< "scale=2;$difftime/60")
    local fileSize="$(stat -f %z "$outfile")"
    fileSize=$(bc <<< "scale=2;$fileSize/1024/1024/1024")
    printf "\n\e[32m\e[1mRipped %sGB in %s minutes\e[0m\n\n" $fileSize $difftime
    
    # MakeMKV doesn't return non-zero on failure, so we need to check the messages
    if [[ $(grep -i "Backup failed" "${temp_dir}/messages.txt") ]] ; then
    	printf '\n\e[31m\e[1mMakeMKV seems to have failed\e[0m\n\n'
    	return 1
    fi
}

function renameOutput {
	# This requires bash 4.x to work
	read -e -p "Enter new name: " -i "$volume_name" volume_name
	outfile="$temp_dir/$volume_name.iso"
}

function copy {
    printf -- "Uploading $volume_name...\n"
    scp -i "${sshKey}" "${outfile}" "${targetServer}:${targetDir}/"
    if [[ $? != 0 ]] ; then
		printf '\n\e[31m\e[1mRemote copy failed\e[0m\n\n'
        return 1
	fi
    rm -rf "${outfile}"
    printf -- "\n\e[32m\e[1m${volume_name} upload complete\e[0m\n\n"
}

trap exitScript EXIT

initTerm
setup

# Main loop
while true ; do
    rip
    if [[ $! != 0 ]] ; then
		error="Rip failed, check messages"
		read -p "Continue?"
    fi
    
    copy
    diskutil eject $source_device
    read -p $'\n\e[34m\e[1mPress return to continue\e[0m' continue
    if [[ -z $continue ]] ; then
        printf -- "\n------------\n"
        continue
    else
        break
    fi
done

deinitTerm

exit 0
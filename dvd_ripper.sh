#! /usr/bin/env bash

# set -x

# Global config
temp_dir="/Users/bamersbach/Desktop/MakeMKV"
targetServer="bamersbach@server.mac-anu.com"
sshKey="/Users/bamersbach/.ssh/id_rsa"
targetDir="/Volumes/Data_RAID/DVD Rips"

# Variables for ripping
source_device=""
volume_name=""
outfile=""
error=""

# Terminal config variables
termHeight=""
termWidth=""
scrollHeight=""

function initTerm {
	termHeight=$(tput lines)
	termWidth=$(tput cols)
	scrollHeight=$(($termHeight - 3))
	printf "\e[?1049h"				# Enable alternate screen buffer
	printf '\e[1;'$scrollHeight'r'	# Set scroll region
}

function deinitTerm {
	printf "\e[?25h"				# Show cursor
	printf '\e[49m\e[39m'			# Restore default colors
	printf '\e[?1049l'				# Disable alternate screen buffer
	printf '\e[1;'$termHeight'r'	# Reset scroll region
}

function exitScript {
	# Uh-oh gotta go
	[[ $(pgrep makemkvcon) ]] && pkill makemkvcon
	deinitTerm
	
	[[ -z "${error}" ]] || printf '\e[31m\e[1mFatal: %s\e[0m\n\n' "${error}"
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
	
	# Clean up the previous files
	rm -f "${temp_dir}/messages.txt"
	rm -f "${temp_dir}/progress.txt"
}

function progress {
	local msgLength="0"
	local linesToPrint=""
	local progHeight=$(($termHeight - 1))
	
	printf "\e[?25l"	# Hide cursor
	printf "\e[s"		# Save cursor position
	
	while true ; do
		# Make sure the terminal hasn't changed on us
		[[ $(tput lines) != "${termHeight}" ]] && initTerm		
		
		printf '\e['$progHeight';0H'	# Move to bottom of screen
		
		# Do a bunch of ANSI terminal stuff and show the current progress
		local currentAction="$(grep -i "Current action" "${temp_dir}/progress.txt" 2>/dev/null | \
			tail -n 1)"
		local progressLine="$(tail -n 1 "${temp_dir}/progress.txt")"
		printf '\e[0;30m\e[102m\e[0J %s \n %s\e[49m\e[39m' \
			"${currentAction}" "${progressLine}"
		sleep 1		
		
		[[ $(pgrep makemkvcon) ]] || break # Bail if makemkvcon is no longer running
	done
	
	printf '\e['$progHeight';0H'	# Move to bottom of screen
	printf '\e[\e[0J'				# Erase to end of screen
	printf "\e[u"					# Restore cursor position
	printf "\e[?25h"				# Show cursor

	return 0
}

function rip {
	ripConfig
	
    printf -- "\nRipping $volume_name...\n"
    local starttime="$(date "+%s")"
    diskutil unmount /dev/$source_device
	
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
    	backup disc:"$discId" "$outfile" &
    
    progress
    
    local endtime="$(date "+%s")"
    local difftime=$(("$endtime"-"$starttime"))
    difftime=$(bc <<< "scale=2;$difftime/60")
    local fileSize="$(stat -f %z "$outfile")"
    fileSize=$(bc <<< "scale=2;$fileSize/1024/1024/1024")
    printf "\n\e[32m\e[1mRipped %sGB in %s minutes\e[0m\n\n" $fileSize $difftime
    
    # MakeMKV doesn't return non-zero on failure, so we need to check the messages
    grep -i "Backup done" "${temp_dir}/messages.txt"
    if [[ $? != 0 ]] ; then
    	printf "\n\e[31m\e[1mMakeMKV seems to have failed, check messages\e[0m\n\n"
    	return 1
    fi
}

function renameOutput {
	# This requires bash 4.x to work
	read -e -p "Enter new name: " -i "$volume_name" volume_name
	outfile="$temp_dir/$volume_name.iso"
}

function copy {
    printf -- "\nUploading $volume_name...\n"
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
		copy || read -p "Copy failure, continue?"
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
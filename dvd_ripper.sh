#! /usr/bin/env bash

# set -x

# Dependencies:
# macOS
# bash 4.x
# MakeMKV

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
bannerMsg="DVD Ripper"

function initTerm {
	termHeight=$(tput lines)
	termWidth=$(tput cols)
	scrollHeight=$(($termHeight - 3))
	local bannerLen=${#bannerMsg}
	local spacing=$(bc <<< "(${termWidth}-${bannerLen})/2-1")
	printf '\e[0J'					# Clear to end of screen to clean up any artifacts
	printf '\e[0;0H'				# Move to top left corner
	# Print banner
	printf '\e[0;30m\e[107m\e[1m \e[%sb%s \e[%sb\e[0K\e[0m\n' \
		$spacing "${bannerMsg}" $spacing
	printf '\e[3;'$scrollHeight'r'	# Set scroll region
	# Move to start of third line and reset colors
	printf '\e[49m\e[39m\e[22m\e[3;0H'				
}

function deinitTerm {
	printf "\e[?25h"				# Show cursor
	printf '\e[49m\e[39m'			# Restore default colors
	printf '\e[1;'$termHeight'r'	# Reset scroll region
	printf '\e[?1049l'				# Disable alternate screen buffer

}

function exitScript {
	# Uh-oh gotta go
	[[ $(pgrep makemkvcon) ]] && pkill makemkvcon
	deinitTerm
	
	[[ -z "${error}" ]] || printf '\n\e[31m\e[1mFatal: %s\e[0m\n' "${error}"
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
    [[ "${PIPESTATUS[0]}" -eq 0 ]] || (echo "Disc not ready" ; return 1)
    outfile="${temp_dir}/$volume_name.iso"
    discId="$(makemkvcon -r info disc | grep ${source_device} | \
    	cut -d ',' -f 1 | tail -c 2)"

	# Confirming settings
    printf -- "Source device: ${source_device}\n"
    printf -- "Output file: ${outfile}\n"
    printf -- "Disc ID: ${discId}\n"
    
    # Get output file name
    local response=""
    read -t 15 -p $'\e[34m\e[1mPress return to continue or n to rename file: \e[0m' response
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
	ripConfig || (echo "Rip config failure" ; return 1)
	
    printf -- "\n\e[1mRipping $volume_name...\e[22m\n"
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
    
    # MakeMKV doesn't return non-zero on failure, so we need to check the messages
    grep -i "Backup done" "${temp_dir}/messages.txt"
    if [[ $? != 0 ]] ; then
    	printf "\n\e[31m\e[1mMakeMKV seems to have failed, check messages\e[0m\n\n"
    	return 1
    fi
    
    local endtime="$(date "+%s")"
    local difftime=$(("$endtime"-"$starttime"))
    difftime=$(bc <<< "scale=2;$difftime/60")
    local fileSize="$(stat -f %z "$outfile")"
    fileSize=$(bc <<< "scale=2;$fileSize/1024/1024/1024")
    printf "\n\e[32m\e[1mRipped %sGB in %s minutes\e[0m\n\n" $fileSize $difftime
}

function renameOutput {
	# This requires bash 4.x to work
	read -e -p "Enter new name: " -i "$volume_name" volume_name
	outfile="$temp_dir/$volume_name.iso"
}

function copy {
    printf -- "\n\e[1mUploading $volume_name...\e[22m\n"
    scp -i "${sshKey}" "${outfile}" "${targetServer}:${targetDir}/"
    if [[ $? != 0 ]] ; then
		printf '\n\e[31m\e[1mRemote copy failed\e[0m\n\n'
        return 1
	fi
    rm -rf "${outfile}"
    printf -- "\n\e[32m\e[1m${volume_name} upload complete\e[0m\n\n"
}

trap exitScript EXIT

printf "\e[?1049h"	# Enable alternate screen buffer
initTerm
setup

# Main loop
while true ; do
	rip && (copy || read -p "Copy failure, continue?")
	read -p $'\e[34m\e[1mPress return to eject disc\e[0m\a'
	diskutil eject $source_device
	read -p $'\n\e[34m\e[1mPress return to continue\e[0m' continue
	if [[ -z $continue ]] ; then
		printf '\n\e(0q\e[%sb\e(2\n\n' $(("$termWidth"-1))	# Horizontal divider line
		continue
	else
		break
	fi
done

deinitTerm

exit 0
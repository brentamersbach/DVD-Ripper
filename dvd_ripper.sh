#! /usr/bin/env bash

# set -x

# Dependencies:
# macOS
# bash 4.x or greater
# MakeMKV
# GNU sed

####################################### Variables ########################################


# Global config
sourceDisk=""					# Device in /dev we are reading from
temp_dir="$HOME/Desktop"		# Where to store the output file and logs while ripping
targetUser=""					# User for login to remote server
targetServer=""					# Remote server to copy ripped files to
sshKey=""						# SSH key for remote server login
targetDir=""					# Directory on remote server to copy into

# Global state
error=""

# Terminal config variables
termHeight=""
termWidth=""
scrollHeight=""
bannerMsg="DVD Ripper"

# Variables for ripping
source_device=""
volume_name=""
outfile=""

####################################### Functions ########################################

function initTerm {
	termHeight=$(tput lines)
	termWidth=$(tput cols)
	scrollHeight=$(($termHeight - 4))
	local bannerLen=${#bannerMsg}
	local spacing=$(bc <<< "(${termWidth}-${bannerLen})/2-1")
	
	tput civis						# Hide cursor
	stty -echo						# Hide input
	tput ed							# Clear to end of screen to clean up any artifacts
	tput cup 0 0					# Move to top left corner
	# Print banner
	printf '\e[0;30m\e[107m\e[1m \e[%sb%s \e[%sb\e[0K\e[0m\n' \
		$spacing "${bannerMsg}" $spacing
	tput csr 3 "${scrollHeight}"	# Set scroll region
	tput sgr0						# Reset colors
	tput cup 3 0					# Move to start of third line
}

function deinitTerm {
	stty echo						# Show input
	tput sgr0						# Restore default colors
	tput csr 1 "($termHeight)"		# Reset scroll region
	tput rmcup						# Disable alternate screen buffer
	tput cvvis						# Show cursor
}

# Let's banish some of this ANSI formatting nightmare into functions

function printSuccess {
	local message="$1"
	printf '\n\e[32m\e[1m%s\e[0m\n' "${message}"
}

function printNotice {
	local message="$1"
	printf '\n\e[1m%s\e[22m\n' "${message}"
}

function printRequest {
	local message="$1"
	printf '\e[34m\e[1m\n%s\e[0m\a\n' "${message}"
}

function printError {
	local message="$1"
	printf '\n\e[31m\e[1m%s\e[0m\n' "${message}"
}

function printDivider {
	local width=$1
	printf '\n\e(0q\e[%sb\e(2\n\n' "${width}"
}

function flushInput {
	# This is needed to prevent stray characters 
	# in the stdin buffer from causing weird behavior
	ttySettings=$(stty -g)
    stty -icanon min 0 time 0

    while read none; do :; done 

    stty $ttySettings
}

function processOptions {
	while getopts "d:t:u:s:k:o:" option ; do
		case "${option}" in
			d) source_device="$OPTARG" ;;
			t) temp_dir="$OPTARG" ;;
			u) targetUser="$OPTARG" ;;
			s) targetServer="$OPTARG" ;;
			k) sshKey="$OPTARG" ;;
			o) targetDir="$OPTARG" ;;
		esac	
	done

	# Check global configs and bail if any are empty
	# If not empty, are they valid? I dunno, who cares.
	[[ -z "${temp_dir}" ]] && fatal "Temp directory not specified"
	[[ -z "${targetUser}" ]] && fatal "SSH user not specified"
	[[ -z "${targetServer}" ]] && fatal "Target SSH server not specified"
	[[ -z "${sshKey}" ]] && fatal "SSH key not specified"
	[[ -z "${targetDir}" ]] && fatal "Target directory not specified"	
}	

function setup {
    local diskList="$(diskutil list external physical)"
    [[ -z $diskList ]] && fatal "No Disc"
    
    if [[ -z $source_device ]] ; then
		source_device="$(grep -e 'disk\d$' <<< "${diskList}"| head -n 1 | \
			awk '{print $NF}')"
			
		echo "${diskList}"
		tput cvvis ; stty echo
		# This requires bash 4.x to work
		flushInput ; read -re \
			-p "$(printRequest "Use which disk? ")" \
			-i "${source_device}" \
			source_device
		tput civis ; stty -echo
	fi
	
	printNotice "Config Summary:"
	printf 'Source Device: %s\n' "${source_device}"
	printf 'Temp Directory: %s\n' "${temp_dir}"
	printf '\nSSH User: %s\n' "${targetUser}"
	printf 'Target Server: %s\n' "${targetServer}"
	printf 'SSH Key: %s\n' "${sshKey}"
	printf 'Target Directory: %s\n' "${targetDir}" 

    printDivider $(("$termWidth"-1))
}

function ripConfig {
    # Using volume name as the name of the output .iso file. Piping through 
    # xargs trims leading/trailing whitespace
    local volumeInfo="$(diskutil info ${source_device})"
    [[ $? -eq 0 ]] || (printError "Disc not ready" ; return 1)
    volume_name="$(\
        grep "Volume Name" <<< "${volumeInfo}" \
        | xargs \
        | cut -d ' ' -f 3-\
    )"
    local mediaType="$(\
    	grep -i "Optical Media Type" <<< ${volumeInfo} \
    	| awk '{print $NF}'\
	)"
    local sourceSize="$(\
    	grep -i "Disk Size" <<< ${volumeInfo} \
    	| cut -w -f 4-5 \
    	| sed 's/\t/ /'\
    )"
    
    discId="$(\
    	makemkvcon -r info disc \
    	| grep ${source_device} \
    	| cut -d ',' -f 1 \
    	| tail -c 2\
	)"

	# Confirming settings
	printf -- "Media type: ${mediaType}\n"
    printf -- "Source size: ${sourceSize}\n"
    printf -- "Output file name: ${volume_name}\n"
    printf -- "MakeMKV Disc ID: ${discId}\n"
    
    # Get output file name
    
    printRequest "[r]ename file or press any key to continue"
    flushInput ; read -rs -n 1 -t 15 -p "$()"
    if [[ "$REPLY" = "r" ]] ; then
    	renameOutput
    fi
    
    # Does that file already exist? We don't want to clobber something.
	local safeTargetPath="$(gsed -E 's/([^\\]) /$1\\ /g' <<< "${safeTargetDir}/${volume_name}")"
	[[ "${mediaType}" = "DVD-ROM" ]] && safeTargetPath+=".iso"
	
    if ssh -i "$sshKey" "$targetServer" "stat $safeTargetPath" &>/dev/null ; then
    	printError "File exists on target, choose something else" && renameOutput
	fi
	
	outfile="${temp_dir}/${volume_name}"
    [[ "${mediaType}" = "DVD-ROM" ]] && outfile+=".iso"
	
	# Clean up the previous files
	rm -f "${temp_dir}/messages.txt"
	rm -f "${temp_dir}/progress.txt"
}

function progress {
	local msgLength="0"
	local linesToPrint=""
	local progHeight=$(($termHeight - 3))
	
	tput sc		# Save cursor position
	
	while true ; do
	
		# Make sure the terminal hasn't changed on us
		[[ $(tput lines) != "${termHeight}" ]] && initTerm		
		
		tput cup $progHeight 0	# Move to start of progress area
		
		# Do a bunch of ANSI terminal stuff and show the current progress
		local currentOperation="$(grep -i "Current operation" "${temp_dir}/progress.txt" 2>/dev/null | \
			tail -n 1)"
		local currentAction="$(grep -i "Current action" "${temp_dir}/progress.txt" 2>/dev/null | \
			tail -n 1)"
		local currentProgress="$(grep -i "Current progress" "${temp_dir}/progress.txt" 2>/dev/null | \
			tail -n 1)"
		printf '\e[0;30m\e[102m\e[0J %s\n %s\n\e[1m %s\e[22m\e[49m\e[39m' \
			"${currentOperation}" "${currentAction}" "${currentProgress}"
		sleep 1		
		
		[[ $(pgrep makemkvcon) ]] || break # Bail if makemkvcon is no longer running
	done
	
	tput cup $progHeight 0	# Move to start of progress area
	tput rc					# Restore cursor position
	tput ed					# Erase to end of screen

	return 0
}

function rip {
	ripConfig || (printError "Rip config failure" ; return 1)
	
    printNotice "Ripping ${volume_name}..."
    local starttime="$(date "+%s")"
    diskutil unmount /dev/$source_device 1>/dev/null
	
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
    	printError "MakeMKV seems to have failed, check messages"
    	return 1
    fi
    
    # Calculate time spent on ripping
    local endtime="$(date "+%s")"
    local difftime=$(("$endtime"-"$starttime"))
    # Get total size of output in MB
    local fileSize=$(bc <<< "scale=2;$(du -mc "${outfile}" | tail -n 1 | cut -f 1)")
    # Calculate approximate rip data rate
    local dataRate=$(bc <<< "scale=2;$fileSize/$difftime")
    
	difftime=$(bc <<< "scale=2;$difftime/60")		# Convert to minutes
    fileSize=$(bc <<< "scale=2;$fileSize/1024")		# Convert to gigabytes
    printSuccess "Ripped ${fileSize}GB in ${difftime} minutes (${dataRate} mbps)"
}

function renameOutput {
	# This requires bash 4.x to work
	tput cvvis ; stty echo
	flushInput ; read -re -p "Enter new name: " -i "$volume_name" volume_name
	tput civis ; stty -echo
}

function copy {
	local starttime="$(date "+%s")"
    printNotice "Uploading $volume_name at $(date +%H:%M:%S)..."
    
#     local safeTargetDir=$(gsed -E 's/([^\]) /\1\\ /g' <<< $targetDir)
    scp -r -i "${sshKey}" "${outfile}" "${targetUser}@${targetServer}":"${targetDir}/" 1>/dev/null
    if [[ $? != 0 ]] ; then
		printError "Remote copy failed"
        return 1
	fi
	
	local fileSize=$(bc <<< "scale=2;$(du -mc "${outfile}" | tail -n 1 | cut -f 1)")
	local endtime="$(date "+%s")"
    local difftime=$(("$endtime"-"$starttime"))
    local dataRate=$(bc <<< "scale=2;$fileSize/$difftime")
    difftime=$(bc <<< "scale=2;$difftime/60")		# Convert to minutes
    
    rm -rf "${outfile}"
    printSuccess "${volume_name} upload complete at $(date +%H:%M:%S) (${dataRate} mbps)"
}

function fatal {
	error="$1"
	exit 1
}

function cleanup {
	# Uh-oh gotta go
	[[ $(pgrep makemkvcon) ]] && pkill makemkvcon
	deinitTerm
	
	[[ -z "${error}" ]] || printError "Fatal: ${error}"
}

###################################### Main Program ######################################

trap cleanup EXIT

processOptions "$@"	# Have to pass in argv for getopts to work inside a function

tput smcup	# Enable alternate screen buffer

initTerm
setup

# Main loop
while true ; do
	rip && (copy || read -p "$(printError "Copy failure, press any key to continue")")
	
	printRequest "Press any key to eject disc"
	flushInput ; read -rs -n 1
	printf 'Please wait...\n'
	diskutil eject $source_device &>/dev/null
	
	printRequest "Press any key to continue or [q]uit"
	flushInput ; read -rs -n 1 -t 300
	if [[ $REPLY = "q" ]] ; then
		break
	else
		printDivider $(("$termWidth"-1))
		continue
	fi
done

deinitTerm

exit 0
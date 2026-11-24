#!/usr/bin/env bash

# set -x
# trap read debug

temp_dir="/Users/bamersbach/Desktop/DVDTemp"
infile="$1"
filePrefix="$(basename "${infile}" | sed -e 's/\.iso$//')"

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

function cleanup {
	# Uh-oh gotta go
	while [[ $(pgrep HandBrakeCLI) != "" ]] ; do
		printNotice "Killing HandBrakeCLI processes, please wait..."
		pkill HandBrakeCLI
		sleep 1
	done
	tput cvvis						# Show cursor
	exit 0	
}

function transcodeDVD {    
    printNotice "Transcoding ${filePrefix} at $(date +%H:%M:%S)..."
    
    printf 'Scanning for titles...'
    local titleMax
    titleMax="$(HandBrakeCLI \
    	-t 0 \
		-i "$infile" 2>&1 \
		| grep -e '\+ title.*' \
		| tail -n 1 \
		| cut -d " " -f 3 \
		| sed -e 's/\://g')"
	printf 'done.\n'	
	printf 'Found %s titles\n' "${titleMax}"
			
    local starttime ; starttime="$(date "+%s")"
	local outdir="${temp_dir}/${filePrefix}"
	mkdir -p "${outdir}"
	local handbrakeLog="${outdir}/${filePrefix}-handbrake.txt"
	
	for title in $(seq -w 1 "${titleMax}") ; do
		printf 'Encoding title %s/%s at %s\n' "${title}" "${titleMax}" "$(date +%H:%M:%S)"

		HandBrakeCLI \
			--preset-import-gui --no-dvdnav \
			-Z "DVD Transcode" \
			-t "${title}" \
			-i "${infile}" \
			-o "${outdir}/${filePrefix}-${title}.mkv" 2>&1 \
		| cat >> "${handbrakeLog}"
		( [[ ${PIPESTATUS[0]} -eq 0 ]] && printf '\e[32m\e[1m%s\e[0m\n' " OK" ) || printf '\e[31m\e[1m%s\e[0m\n' " Failed"
	done		

	local endtime ; endtime="$(date "+%s")"
	local difftime
	difftime=$(bc <<< "${endtime}-${starttime}")
    difftime=$(bc <<< "scale=2;$difftime/60")		# Convert to minutes
		
	printSuccess "${filePrefix} transcode complete at $(date +%H:%M:%S) (${difftime} minutes)"
		
}

function transcodeBD {
    printNotice "Transcoding $filePrefix at $(date +%H:%M:%S)..."
    
	local starttime ; starttime="$(date "+%s")"
	local outdir="${temp_dir}/${filePrefix}"
	mkdir -p "${outdir}"
	local handbrakeLog="${outdir}/${filePrefix}-handbrake.txt"
	
	printf 'Scanning for titles...'
	local titleMax
	titleMax="$(HandBrakeCLI \
    	-t 0 \
		-i "${infile}/BDMV/STREAM" 2>&1 \
		| tee "${handbrakeLog}" \
		| grep -e '\+ title.*' \
		| tail -n 1 \
		| cut -d " " -f 3 \
		| sed -e 's/\://g')"
	printf 'done.\n'
	printf 'Found %s titles\n' "${titleMax}"
	
	for title in $(seq -w 1 "${titleMax}") ; do
		printf 'Encoding title %s/%s at %s... ' "${title}" "${titleMax}" "$(date +%H:%M:%S)"
		printf '\n---------------- Title %s ----------------\n\n' "${title}" >> "${handbrakeLog}"
		
		HandBrakeCLI \
			--preset-import-gui \
			-Z "BD Transcode HD" \
			-t "${title}" \
			-i "${infile}/BDMV/STREAM" \
			-o "${outdir}/${filePrefix}-${title}.mkv" 2>&1 \
		| cat >> "${handbrakeLog}"
		( [[ ${PIPESTATUS[0]} -eq 0 ]] && printf '\e[32m\e[1m%s\e[0m\n' " OK" ) || printf '\e[31m\e[1m%s\e[0m\n' " Failed"
	done
		
	local endtime ; endtime="$(date "+%s")"
	local difftime ; difftime=$(bc <<< "${endtime}-${starttime}")
    difftime=$(bc <<< "scale=2;$difftime/60")		# Convert to minutes
		
	printSuccess "${filePrefix} transcode complete at $(date +%H:%M:%S) (${difftime} minutes)"
}

function transcode {
	local fileType ; fileType=$(stat -f "%HT" "$infile")
	local fileExt ; fileExt="$(tail -c 5 <<<"${infile}")"
	
	if [[ $fileType = "Regular File" ]] && [[ $fileExt = ".iso" ]]; then
		printNotice "Detected DVD ISO"
		transcodeDVD
		return
	elif [[ $fileType = "Directory" ]] && [[ -d "${infile}/BDMV" ]] ; then
		printNotice "Detected BDMV folder"
		transcodeBD
		return
	else 
		printError "Invalid input file, not a DVD ISO or folder containing BDMV"
		exit 1
	fi
}

trap cleanup EXIT

tput civis						# Hide cursor
transcode
tput cvvis						# Show cursor

exit 0
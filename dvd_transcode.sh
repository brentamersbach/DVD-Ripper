#/usr/bin/env bash

# set -x
# trap read debug

temp_dir="/Users/bamersbach/Desktop/DVDTemp"
infile="$1"
safeInfile="$(gsed -e 's/ /\\ /g' <<< ${infile})"
# outdir="/Users/bamersbach/Desktop/DVDTemp"
filePrefix=""

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
		pkill HandBrakeCLI
		sleep 1
	done
	tput cvvis						# Show cursor
	exit 0	
}

function transcode {
	rm -f ${temp_dir}/handbrake.txt 	# Clean up previous log
    
    local filePrefix="$(basename "${infile}" | sed -e 's/\.iso$//')"
    
    printNotice "Transcoding ${filePrefix} at $(date +%H:%M:%S)..."
    
    local titleMax="$(HandBrakeCLI \
    	-t 0 \
		-i "$infile" 2>&1 \
		| grep -e '\+ title.*' \
		| tail -n 1 \
		| cut -d " " -f 3 \
		| sed -e 's/\://g')"
	printf 'Found %s titles\n' "${titleMax}"
			
    local starttime="$(date "+%s")"
	local inputDir="$(dirname "${infile}" | sed -e 's/\\//')"
	local outdir="${temp_dir}/${filePrefix}"
	mkdir -p "${outdir}"
	
	for title in $(seq -w 1 ${titleMax}) ; do
		printf 'Encoding title %s/%s at %s\n' "${title}" "${titleMax}" "$(date +%H:%M:%S)"
		HandBrakeCLI \
			--preset-import-gui --no-dvdnav \
			-Z "DVD Transcode" \
			-t "${title}" \
			-i "${infile}" \
			-o "${outdir}/${filePrefix}-${title}.mkv" 2>&1 \
		| cat >> ${temp_dir}/handbrake.txt
		[[ ${PIPESTATUS[0]} -eq 0 ]] || ( printError "Handbrake failed, check log" ; exit 1 )
	done		

	local endtime="$(date "+%s")"
	local difftime=$(bc <<< "${endtime}-${starttime}")
    difftime=$(bc <<< "scale=2;$difftime/60")		# Convert to minutes
		
	printSuccess "${filePrefix} transcode complete at $(date +%H:%M:%S) (${difftime} minutes)"
		
}
trap cleanup EXIT

tput civis						# Hide cursor
transcode
tput cvvis						# Show cursor

exit 0
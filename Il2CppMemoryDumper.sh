#!/system/bin/sh

echo "########################"
echo "# Il2Cpp Memory Dumper #"
echo "# by NekoYuzu neko.ink #"
echo "########################"

if [[ $1 == "" ]]; then
	echo "* Usage: $0 <package> [output]"
	exit
fi

package=$1

if [[ $2 == "" ]]; then
	out=/sdcard/dump
else
	out=$2
fi

echo "- Target package: $package"
echo "- Output directory: $out"

mkdir -p "$out"

user=$(am get-current-user)
pid=$(ps -ef | grep $package | grep u$user | awk '{print $2}')

if [[ $pid == "" ]]; then
	echo "! Target package of current user ($user) not found, is process running?"
	exit
fi

echo "- Found target process: $pid"

targets="global-metadata.dat libil2cpp.so "$(getprop ro.product.cpu.abilist | awk -F',' '{for (i = 1; i <= NF; i++) {gsub(/-/, "_"); print "split_config."$i".apk"}}')

for target in $targets; do
	local maps=$(grep $target /proc/$pid/maps | awk -v OFS='|' '{for (i = 1; i <= NF; i+=6) {print $i,$(i+1),$(i+2),$(i+3),$(i+4),$(i+5)}}')
	if [[ $maps != "" ]]; then
		if [[ $mem_list != "" ]]; then
			mem_list="${mem_list} ${maps}"
		else
			mem_list=$maps
		fi
	fi
done

cp /proc/$pid/maps "$out/${package}_maps.txt"

SYS_PAGESIZE=$(getconf PAGESIZE)
HEX_PAGESIZE=$(printf "%x" $SYS_PAGESIZE)

echo "- Starting dump process..."

lastFile=
lastEnd=
metadataOffset=

for memory in $mem_list; do
	local range=$(echo $memory | awk -F'|' '{print $1}')
	local offset=$(echo $range | awk -F'-' '{print toupper($1)}')
	local end=$(echo $range | awk -F'-' '{print toupper($2)}')
	local memName=$(echo $memory | awk -F'|' '{print $6}' | awk -F'/' '{print $NF}')
	
	if [[ $memName == "global-metadata.dat" ]]; then
		metadataOffset=$offset
		continue
	fi
	
	dd if="/proc/$pid/mem" bs=1 skip=$(echo "ibase=16;$offset" | bc) count=4 of="${out}/tmp" 2>/dev/null
	
	if [[ $(cat "${out}/tmp") == $(echo -ne "\x7F\x45\x4C\x46") ]]; then
		fileExt="so"
	else
		fileExt="dump"
	fi
	
	local fileOut="${out}/${offset}_${package}_${memName}.${fileExt}"
	
	if [[ $metadataOffset != "" ]] && [[ $(echo "ibase=16;(${metadataOffset}-${offset})<0" | bc) -ne 0 ]]; then
		echo "- Dumping [$memName] $range... <- This might be the correct libil2cpp.so"
		metadataOffset=
	else
		echo "- Dumping [$memName] $range..."
	fi
	
	dd if="/proc/$pid/mem" bs=$SYS_PAGESIZE skip=$(echo "ibase=16;${offset}/$HEX_PAGESIZE" | bc) count=$(echo "ibase=16;(${end}-${offset})/$HEX_PAGESIZE" | bc) of="$fileOut" 2>/dev/null
	
	if [[ $fileExt == "so" ]]; then
		lastFile=$fileOut
	else
		if [[ $lastFile != "" ]]; then
			echo "- Merging memory..."
			skipMerge=false
			if [[ $lastEnd != $offset ]]; then
				gap_block=$(echo "ibase=16;(${offset}-${lastEnd})/${HEX_PAGESIZE}" | bc)
				if [[ $gap_block -gt 32 ]]; then
					echo "- Gap blocks $gap_block is too large, skipping merge..."
					skipMerge=true
					lastFile=$fileOut
				else
					echo "- Adding $gap_block gap blocks..."
					dd if="/proc/$pid/mem" bs=$SYS_PAGESIZE skip=$(echo "ibase=16;${lastEnd}/$HEX_PAGESIZE" | bc) count=$gap_block of="$out/tmp" 2>/dev/null
					cat "$out/tmp">>"$lastFile"
				fi
			fi
			if [[ $skipMerge == "false" ]]; then
				cat "$fileOut">>"$lastFile"
				rm -f "$fileOut"
			fi
		else
			echo "- No ELF header found, but nothing to merge. Treating as a raw dump..."
			lastFile=$fileOut
		fi
	fi
	
	lastEnd=$end

	rm -f "${out}/tmp"
done

echo "- Done!"
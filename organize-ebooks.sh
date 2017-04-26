#!/usr/bin/env bash

set -euo pipefail

DIR="$(dirname "$(realpath "${BASH_SOURCE[0]}")")"
# shellcheck source=./lib.sh
. "$DIR/lib.sh"

CORRUPTION_CHECK_ONLY=false
ORGANIZE_WITHOUT_ISBN=false
ORGANIZE_WITHOUT_ISBN_SOURCES="Goodreads,Amazon.com,Google" # Requires Calibre 2.84+, previous versions will search in all enabled sources in the GUI

OUTPUT_FOLDER="$(pwd)"
OUTPUT_FOLDER_SEPARATE_UNSURE=false
OUTPUT_FOLDER_UNSURE="$(pwd)"
OUTPUT_FOLDER_CORRUPT=

DEBUG_PREFIX_LENGTH=40

print_help() {
	echo "eBook Organizer v$VERSION"
	echo
	echo "Usage: $(basename "${BASH_SOURCE[0]}") [OPTIONS] EBOOK_PATHS..."
	echo
	echo "For information about the possible options, see the beginning of the script itself"
}

for i in "$@"; do
	case "$i" in
		-cco|--corruption-check-only) CORRUPTION_CHECK_ONLY=true ;;
		-owi|--organize--without--isbn) ORGANIZE_WITHOUT_ISBN=true ;;
		-owis=*|--organize--without--isbn-sources=*) ORGANIZE_WITHOUT_ISBN_SOURCES="${i#*=}" ;;
		-o=*|--output-folder=*)
			OUTPUT_FOLDER="${i#*=}"
			if [[ "$OUTPUT_FOLDER_SEPARATE_UNSURE" == false ]]; then
				OUTPUT_FOLDER_UNSURE="${i#*=}"
			fi
		;;
		-ou=*|--output-folder-unsure=*)
			OUTPUT_FOLDER_SEPARATE_UNSURE=true
			OUTPUT_FOLDER_UNSURE="${i#*=}"
		;;
		-oc=*|--output-folder-corrupt=*) OUTPUT_FOLDER_CORRUPT="${i#*=}" ;;
		--debug-prefix-length=*) DEBUG_PREFIX_LENGTH="${i#*=}" ;;
		-h|--help) print_help; exit 1 ;;
		-*|--*) handle_script_arg "$i" ;;
		*) break ;;
	esac
	shift # past argument=value or argument with no value
done
if [[ "$#" == "0" ]]; then print_help; exit 2; fi


fail_file() {
	echo -e "${RED}ERR${NC}:\t$1\nREASON:\t$2\n${3+TO:\t$3\n}"
}

skip_file() {
	echo -e "SKIP:\t$1\nREASON:\t$2\n"
}


# Sequentially tries to fetch metadata for each of the supplied ISBNs; if any
# is found, writes it to a tmp .txt file and calls organize_known_ebook()
# Arguments: path, isbn (coma-separated)
organize_by_isbns() {
	local isbn_sources
	IFS=, read -ra isbn_sources <<< "$ISBN_METADATA_FETCH_ORDER"

	local isbn
	for isbn in $(echo "$2" | tr "$ISBN_RET_SEPARATOR" '\n'); do
		local tmpmfile
		tmpmfile="$(mktemp --suffix='.txt')"
		decho "Trying to fetch metadata for ISBN '$isbn' into temp file '$tmpmfile'..."

		local isbn_source
		for isbn_source in "${isbn_sources[@]:-}"; do
			decho "Fetching metadata from ${isbn_source:-all sources}..."
			if fetch_metadata "fetch-meta-${isbn_source:-all}" "${isbn_source:-}" --isbn="$isbn" > "$tmpmfile"; then
				sleep 0.1
				decho "Successfully fetched metadata: "
				debug_prefixer "[meta] " 0 --width=100 -t < "$tmpmfile"

				decho "Addding additional metadata to the end of the metadata file..."
				{
					echo "ISBN                : $isbn"
					echo "All found ISBNs     : $2"
					echo "Old file path       : $1"
					echo "Metadata source     : $isbn_source"
				} >> "$tmpmfile"

				decho "Organizing '$1' (with '$tmpmfile')..."
				move_or_link_ebook_file_and_metadata "$OUTPUT_FOLDER" "$1" "$tmpmfile"
				return
			fi
		done

		decho "Removing temp file '$tmpmfile'..."
		rm "$tmpmfile"
	done

	if [[ "$ORGANIZE_WITHOUT_ISBN" == true ]]; then
		decho "Could not organize via the found ISBNs, organizing by filename and metadata instead..."
		organize_by_filename_and_meta "$1" "Could not fetch metadata for ISBNs '$2'"
	else
		decho "Organization by filename and metadata is not turned on, giving up..."
		skip_file "$1" "Could not fetch metadata for ISBNs '$2'; Non-ISBN organization not turned on"
	fi
}

# Arguments: filename, reason (optional)
organize_by_filename_and_meta() {
	local old_path
	old_path="$1"

	decho "Organizing '$old_path' by non-ISBN metadata and filename..."

	local lowercase_name
	lowercase_name="$(basename "$old_path" | sed -E 's/[[:upper:]]+/\L&/g')"
	if [[ "$lowercase_name" =~ $WITHOUT_ISBN_IGNORE ]]; then
		local matches
		matches="[$(echo "$lowercase_name" | grep -oE "$NO_ISBN_IGNORE_REGEX" | paste -sd';')]"
		decho "Parts of the filename match the ignore regex: [$matches]"
		skip_file "$old_path" "${2:-}${2+; }File matches the ignore regex ($matches)"
		return
	else
		decho "File does not match the ignore regex, continuing..."
	fi

	local ebookmeta
	ebookmeta="$(ebook-meta "$old_path" | grep -E '[a-zA-Z()]+ +: .*' )"
	decho "Ebook metadata:"
	echo "$ebookmeta" | debug_prefixer "	" 0 --width=80 -t

	tmpmfile="$(mktemp --suffix='.txt')"
	decho "Created temporary file for metadata downloads '$tmpmfile'"

	local title
	title="$(echo "$ebookmeta" | grep_meta_val "Title" | sed -E 's/[^[:alnum:]]+/ /g' )"
	local author
	author="$(echo "$ebookmeta" | grep_meta_val "Author" | sed -e 's/ & .*//' -e 's/[^[:alnum:]]\+/ /g' )"
	decho "Extracted title '$title' and author '$author'"

	if [[ "${title//[^[:alpha:]]/}" != "" && "$title" != "Unknown" ]]; then
		decho "There is a relatively normal-looking title, searching for metadata..."

		finisher() {
			decho "Successfully fetched metadata: "
			debug_prefixer "[meta-$1] " 0 --width=100 -t < "$tmpmfile"
			decho "Addding additional metadata to the end of the metadata file..."
			{
				echo "Old file path       : $old_path" >> "$tmpmfile"
				echo "Meta fetch method   : $1" >> "$tmpmfile"
				echo "$ebookmeta" | sed -E 's/^(.+[^ ])   ([ ]+): /OF \1\2: /'
			} >> "$tmpmfile"

			local isbn
			isbn="$(find_isbns < "$tmpmfile")"
			if [[ "$isbn" != "" ]]; then
				echo "ISBN                : $isbn" >> "$tmpmfile"
			fi

			decho "Organizing '$old_path' (with '$tmpmfile')..."
			move_or_link_ebook_file_and_metadata "$OUTPUT_FOLDER_UNSURE" "$old_path" "$tmpmfile"
		}

		if [[ "${author//[[:space:]]/}" != "" && "$author" != "Unknown" ]]; then
			decho "Trying to fetch metadata by title '$title' and author '$author'..."
			if fetch_metadata "fetch-meta-title&author" "$ORGANIZE_WITHOUT_ISBN_SOURCES" --title="$title" --author="$author" > "$tmpmfile"; then
				finisher "title&author"
				return
			fi
			decho "Trying to swap places - author '$title' and title '$author'..."
			if fetch_metadata "fetch-meta-rev-title&author" "$ORGANIZE_WITHOUT_ISBN_SOURCES" --title="$author" --author="$title" > "$tmpmfile"; then
				finisher "rev-title&author"
				return
			fi
		fi

		decho "Trying to fetch metadata only by title '$title'..."
		if fetch_metadata "fetch-meta-title" "$ORGANIZE_WITHOUT_ISBN_SOURCES" --title="$title" > "$tmpmfile"; then
			finisher "title"
			return
		fi
	fi

	local filename
	filename="$(basename "${old_path%.*}" | sed -E 's/[^[:alnum:]]+/ /g')"

	decho "Trying to fetch metadata only the filename '$filename'..."
	if fetch_metadata "fetch-meta-filename" "$ORGANIZE_WITHOUT_ISBN_SOURCES" --title="$filename" > "$tmpmfile"; then
		finisher "filename"
		return
	fi

	decho "Could not find anything, removing the temp file '$tmpmfile'..."
	rm "$tmpmfile"

	skip_file "$old_path" "${2:-}${2+; }Insufficient or wrong file name/metadata"
}


organize_file() {
	local file_err
	file_err="$(check_file_for_corruption "$1")"
	if [[ "$file_err" != "" ]]; then
		decho "File '$1' is corrupt with error '$file_err'"
		if [[ "${OUTPUT_FOLDER_CORRUPT%/}" != "" ]]; then
			local new_path
			new_path="$(unique_filename "${OUTPUT_FOLDER_CORRUPT%/}" "$(basename "$1")")"

			fail_file "$1" "File is corrupt: $file_err" "$new_path"

			$DRY_RUN && decho "(DRY RUN! All operations except metadata deletion are skipped!)"
			if [[ "$SYMLINK_ONLY" == true ]]; then
				decho "Symlinking file '$1' to '$new_path'..."
				$DRY_RUN || ln -s "$(realpath "$1")" "$new_path"
			else
				decho "Moving file '$1' to '$new_path'..."
				$DRY_RUN || mv --no-clobber "$1" "$new_path"
			fi

			local new_metadata_path="${new_path}.${OUTPUT_METADATA_EXTENSION}"
			decho "Saving original filename to '$new_metadata_path'..."
			$DRY_RUN || echo "Corruption reason   : $file_err" >> "$new_metadata_path"
			$DRY_RUN || echo "Old file path       : $1" >> "$new_metadata_path"
		else
			decho "Output folder for corrupt files is not set, doing nothing"
			fail_file "$1" "File is corrupt: $file_err"
		fi
	elif [[ "$CORRUPTION_CHECK_ONLY" == true ]]; then
		decho "We are only checking for corruption, do not continue organising..."
		skip_file "$1" "File appears OK"
	else
		decho "File passed the corruption test, looking for ISBNs..."

		local isbns
		isbns="$(search_file_for_isbns "$1")"
		if [[ "$isbns" != "" ]]; then
			decho "Organizing '$1' by ISBNs '$isbns'!"
			organize_by_isbns "$1" "$isbns"
		elif [[ "$ORGANIZE_WITHOUT_ISBN" == true ]]; then
			decho "No ISBNs found for '$1', organizing by filename and metadata..."
			organize_by_filename_and_meta "$1" "No ISBNs found"
		else
			skip_file "$1" "No ISBNs found; Non-ISBN organization not turned on"
		fi
	fi
	decho "====================================================="
}


for fpath in "$@"; do
	decho "Recursively scanning '$fpath' for files"
	find "$fpath" -type f  -print0 | sort -z | while IFS= read -r -d '' file_to_check
	do
		organize_file "$file_to_check" 2> >(debug_prefixer "[$file_to_check] " "$DEBUG_PREFIX_LENGTH")
	done
done


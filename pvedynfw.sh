#!/bin/bash

# Unofficial dynamic firewall rule updater based on IPs retrieved from DNS
# Author: Tseytisi <tseytisi@proton.me>

# Dependencies
# - dig
# - awk
# - grep

# This code is completely clanker-free

# --- Settings ---
# Enter every firewall file that should be checked for dynamic IP rules
FIREWALL_FILES=(
    # Unquoted, this line expands to every file in the firewall directory
    /etc/pve/firewall/*
    # For more fine-grained control, use manual entries like: (no commas!)
    #"/etc/pve/firewall/cluster.fw"
    #"/etc/pve/firewall/100.fw"
    #"/etc/pve/firewall/101.fw"
)

# Log each check instead of just errors (prints to STDERR)
VERBOSE=false

# Sets behaviour for if the DNS response contains multiple IP address
# false: ignore the response and do not update the firewall
# true: take the first IP from the response
ALLOW_MULTIPLE_RESPONSES=false

# For testing only; writes updates to a temporary file and does not overwrite the actual firewall rules
# Of course, firewall changes will not take effect, and every check will write a new updated file
NO_OVERWRITE=false
# --- End: Settings ---

# "Don't forget to euo pipefail because Bash will take every opportunity to delete your computer" ~ A wise man
set -euo pipefail

# A bunch of Regex (POSIX format :( )
IPV4_matcher="[[:digit:]]{1,3}(\.[[:digit:]]{1,3}){3}"
IPV6_matcher="((^|[[:blank:]]+)(([[:xdigit:]]{1,4}:)+|:)(:|(:[[:xdigit:]]{1,4})+)([[:blank:]]+|$)|[[:xdigit:]]{1,4}(:[[:xdigit:]]{1,4}){7})"

# --- Functions ---
# Parameters:
# 1: domain
# 2: old IPv4
check_ipv4 () {
    response="$(dig "$1" A +noall +answer | awk '{if ($4 == "A") print $5}')"
    if ! $ALLOW_MULTIPLE_RESPONSES && [ `printf "$response\n" | wc -l` -gt 1 ]; then
        >&2 printf "Error: DNS lookup for '%s' returned more than one IPv4 address\n" "$1"
        return
    fi
    if [[ $response =~ $IPV4_matcher ]]; then
        if $VERBOSE; then
            >&2 printf "Received IPv4 response: %s\n" "${BASH_REMATCH}"
        fi
        if [[ $response != $2 ]]; then
            echo "${BASH_REMATCH}"
            return
        elif $VERBOSE; then
            >&2 echo Address did not change
        fi
    else
        >&2 printf "Error: No (valid) response for DNS lookup of domain '%s'\n" "$1"
        return
    fi
}

# Parameters:
# 1: domain
# 2: old IPv6
check_ipv6 () {
    response="$(dig "$1" AAAA +noall +answer | awk '{if ($4 == "AAAA") print $5}')"
    if ! $ALLOW_MULTIPLE_RESPONSES && [ `printf "$response\n" | wc -l` -gt 1 ]; then
        >&2 printf "Error: DNS lookup for '%s' returned more than one IPv6 address\n" "$1"
        return
    fi
    if [[ $response =~ $IPV6_matcher ]]; then
        if $VERBOSE; then
            >&2 printf "Received IPv6 response: %s\n" "${BASH_REMATCH}"
        fi
        # Strip whitespace
        response="$(printf "$response" | xargs)"
        if [[ $response != $2 ]]; then
            echo "${BASH_REMATCH}"
            return
        elif $VERBOSE; then
            >&2 echo Address did not change
        fi
    else
        >&2 printf "Error: No (valid) response for DNS lookup of domain '%s'\n" "$1"
        return
    fi
}
# --- End: Functions ---

TEMP_FILE="/tmp/pvedynfw.tmp"
VERY_TEMP_FILE="/tmp/pvedynfw2.tmp"

# --- Script start ---
# For each file
for filepath in ${FIREWALL_FILES[@]}; do
    if $VERBOSE; then
        >&2 echo "Checking file $filepath"
    fi
    if [ ! -f "$filepath" ]; then
        >&2 printf "Error: File not found '%s'\n" "$filepath"
        continue
    fi

    first_change=true
    source_file="$filepath"
    # For every line in the file with [DYN-IP (A|AAAA) <domain>]
    while read -r line; do
        # The grep used as input to this loop filters out any empty lines
        # UNLESS there are no matches at all, in which case it will return one empty line
        if [[ $line == "" ]]; then
            if $VERBOSE; then
                >&2 echo "Found no dynamic IP entries in file"
            fi
            continue
        fi
        if $VERBOSE; then
            >&2 echo -e "\nChecking entry '$line'"
        fi

        # Do not update disabled firewall rules
        if [[ $line == \|* || $line =~ ^[[:blank:]]*# ]]; then
            if $VERBOSE; then
                >&2 echo Skipping disabled entry
            fi
            continue
        fi

        # For whatever reason this regex cannot be in a variable
        if [[ $line =~ \[DYN-IP[[:blank:]]+([[:alnum:]]+)[[:blank:]]+([^\][:blank:]]+)[[:blank:]]*\] ]]; then
            rule="$(printf "$line" | cut -d '#' -f 1)"
            record="${BASH_REMATCH[1]}"
            domain="${BASH_REMATCH[2]}"
            replacement=""
            declare address
            case "$record" in
                A)
                    if [[ $rule =~ $IPV4_matcher ]]; then
                        address="${BASH_REMATCH}"
                        replacement="$(check_ipv4 "$domain" "$address")"
                        if [ -z "$replacement" ]; then
                            # Empty string return value is either no update
                            # or some error; either way don't update the firewall
                            continue
                        fi

                        # Sanity-check; it's very easy to return something extra from
                        # a Bash function and this is the last check before we update
                        # the firewall
                        if [[ ! $replacement =~ $IPV4_matcher ]]; then
                            >&2 printf "ERROR: Invalid return from IPv4 check '%s' (this is a bug, please report this)\n" "$replacement"
                            continue
                        fi
                    else
                        >&2 printf "Error: Did not find a valid IPv4 address in rule on line: (file: %s) %s\n" "$filepath" "$line"
                    fi
                    ;;
                AAAA)
                    if [[ $rule =~ $IPV6_matcher ]]; then
                        # Strip whitespace
                        address="$(printf "${BASH_REMATCH}" | xargs)"
                        replacement="$(check_ipv6 "$domain" "$address")"
                        if [ -z "$replacement" ]; then
                            continue
                        fi

                        # Sanity-check
                        if [[ ! $replacement =~ $IPV6_matcher ]]; then
                            >&2 printf "ERROR: Invalid return from IPv6 check '%s' (this is a bug, please report this)\n" "$replacement"
                            continue
                        fi
                    else
                        >&2 printf "Error: Did not find a valid IPv6 address in rule on line: (file: %s) %s\n" "$filepath" "$line"
                    fi
                    ;;
                *)
                    >&2 printf "Error: Unrecognised DNS record type '%s'\n" "$record"
                    continue
            esac

            if [ ! -z "$replacement" ]; then
                # If we're here; we have a valid and new IP to update the firewall with
                >&2 printf "Found new IP for domain '%s' (%s -> %s)\n" "$domain" "$address" "$replacement"

                # Write an updated file and update the line we're checking
                awk '$0 == orig { sub("'"$address"'", "'"$replacement"'") } { print }' orig="$line" "$source_file" > "$VERY_TEMP_FILE"
                mv "$VERY_TEMP_FILE" "$TEMP_FILE"

                # First change, we read from the original file;
                # any subsequent change, we read from the temporary file
                # if we did this at least once, at the end, overwrite the original with the temp file
                if $first_change; then
                    first_change=false
                    source_file="$TEMP_FILE"
                fi
            fi
        else
            >&2 printf "Error: Malformed dynamic IP entry (file %s): %s\n" "$filepath" "$line"
        fi
    done <<< "$(grep -P '\[DYN-IP[^\]]*\]' "$filepath")"

    if ! $first_change; then
        if [ -f "$TEMP_FILE" ]; then
            # Only one write, and mv (on the same filesystem) is atomic
            # So PVE should only notice one firewall update
            if ! $NO_OVERWRITE; then
                # Give the replacement file the same permissions as the current version
                cp -p --attributes-only "$filepath" "$TEMP_FILE"
                mv "$TEMP_FILE" "$filepath"
                >&2 printf "Updated firewall file '%s'\n" "$filepath"
            else
                not_so_temp_file="/tmp/$(basename "$filepath").new"
                mv "$TEMP_FILE" "$not_so_temp_file"
                >&2 printf "Update for firewall '%s' written to '%s'\n" "$filepath" "$not_so_temp_file"
            fi
        else
            >&2 printf "Firewall should have been updated but the changed file is gone (this is a bug, please report this)\n"
        fi
    fi
done

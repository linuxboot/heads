#!/bin/bash

# Check if gpg is installed
if ! command -v gpg &> /dev/null; then
    echo "gpg could not be found. Please install gpg and try again."
    exit 1
fi

# Check if git is installed
if ! command -v git &> /dev/null; then
    echo "git could not be found. Please install git and try again."
    exit 1
fi

# Remove existing artifacts
rm -f signatures.txt keys.txt not_found_keys.txt error_log.txt success_log.txt unfound_keys_users.txt
rm -rf keys

# Extract signatures from git log
git log --show-signature > signatures.txt

# Parse the signatures and extract unique keys
grep -oP 'using (RSA|DSA|ECDSA|EDDSA) key \K\w+' signatures.txt | sort | uniq > keys.txt

# Define key servers to try
key_servers=(
    "hkp://keyserver.ubuntu.com"
    "hkp://keys.openpgp.org"
    "hkp://pgp.mit.edu"
    "hkp://keyserver.pgp.com"
    "hkp://keys.gnupg.net"
    "hkp://pgp.surfnet.nl"
    "hkp://keyserver.cryptonomica.com"
    "hkp://keyserver.freenet.de"
    "hkp://keyserver.kjsl.com"
)

# Function to shuffle array
shuffle() {
    local i tmp size max rand
    size=${#key_servers[*]}
    max=$(( 32768 / size * size ))
    for ((i=size-1; i>0; i--)); do
        while (( (rand=RANDOM) >= max )); do :; done
        rand=$(( rand % (i+1) ))
        tmp=${key_servers[i]}
        key_servers[i]=${key_servers[rand]}
        key_servers[rand]=$tmp
    done
}

# Create keys directory
mkdir -p keys

# Fetch and save the public keys from key servers
while read -r key; do
    found=false
    shuffle
    # Extract user information for the key
    user=$(grep -A3 -B3 "$key" signatures.txt | grep 'Author:' | head -n 1 | sed 's/Author: //')
    if [ -z "$user" ]; then
        user="Unknown"
    fi
    echo "Debug: Key = $key, User = $user"  # Debugging statement
    echo "Attempting to fetch key $key for user $user"
    for server in "${key_servers[@]}"; do
        echo "Trying server $server"
        if ! ping -c 1 -W 1 "${server#*//}" &> /dev/null; then
            echo "Server $server could not be reached." >> error_log.txt
            continue
        fi
        if gpg --keyserver "$server" --recv-keys "$key"; then
            gpg --export --armor "$key" > "keys/key_$key.asc"
            found=true
            echo "Successfully retrieved key $key from $server" >> success_log.txt
            break
        else
            echo "Failed to retrieve key $key from $server" >> error_log.txt
        fi
    done
    if [ "$found" = false ]; then
        echo "Key $key not found on any key server." | tee -a not_found_keys.txt
        echo "Key $key not found for user $user" >> unfound_keys_users.txt
    fi
done < keys.txt


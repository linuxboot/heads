#!/bin/ash
#Credit to https://github.com/JamesBarwell/diceware-bash/commit/5023de5798ecd633d33d1e6fc3b69b00972678f5

usage() {
    echo "diceware.sh - a tool to select random words from a source, to generate a strong passphrase"
    echo ""
    echo "Usage:"
    echo "diceware.sh /path/to/source/text [selection_count] [UppercaseFirstLetters] [NoSpaceBetweenWords]"
    echo "  /path/to/source/text - mandatory filepath to source text file"
    echo "  selection_count - optional, number of random words to select from source, defaults to 7"
}

main() {
    source=$1
    select_count=$2
    uppercaser_first_letters=$3
    no_space=$4

    if [ -z "$source" ] || [ "$source" == "-h" ] || [ "$source" == "--help" ]; then
        usage
        exit 1
    fi

    if ! [[ "$select_count" -eq "$select_count" ]] 2>/dev/null ; then
        select_count=7
    fi

    wordcount=$(cat $source | tr -cs A-Za-z '\n' | tr A-Z a-z | sort | uniq | wc -l)

    if [ $wordcount -lt 7776 ]; then
        echo "Warning: source contains only $wordcount unique words, which is below the limit of 7776 to ensure a strong passphrase"
    fi

    passphrase=$(cat $source | tr -cs A-Za-z '\n' | tr A-Z a-z | sort | uniq | shuf -n$select_count)
    
    if [ -n "$uppercaser_first_letters" ]; then
      temp=$(echo $passphrase | awk '{for(i=1;i<=NF;i++){ $i=toupper(substr($i,1,1)) substr($i,2) }}1')
      passphrase=$temp
    fi

    if [ -n "$no_space" ]; then
      temp=$(echo $passphrase | tr -d ' ' )
      passphrase=$temp
    fi

    echo $passphrase

}
main $@

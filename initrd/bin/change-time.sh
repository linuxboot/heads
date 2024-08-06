#!/bin/bash
#change time using hwclock and date -s

clear

echo -e -n "Please enter the current date and time in UTC\n"
echo -e -n "To find the current date and time in UTC, please check https://time.is/UTC\n\n"


get_date () {
    local field_name min max
    field_name="$1"
    min="$2"
    max="$3"
    echo -n "Enter the current $field_name [$min-$max]: "
    read -r value
    echo

    #must be a number between $2 and $3
    while [[ ! $value =~ ^[0-9]+$ ]] || [[ ${value#0} -lt $min ]] || [[ ${value#0} -gt $max ]];
    do
        echo "Please try again, it must be a number from $min to $max."
        echo -n "Enter the current $field_name [$min-$max]: "
        read -r value
        echo
    done

    # Pad with zeroes to length of maximum value
    value="$(printf "%0${#max}u" "$value")"
}

enter_time_and_change()
{
    get_date "year" "2024" "2200"
    year=$value
    get_date "month" "01" "12"
    month=$value
    get_date "day" "01" "31"
    day=$value
    get_date "hour" "00" "23"
    hour=$value
    get_date "minute" "00" "59"
    min=$value
    get_date "second" "00" "59"
    sec=$value

    if ! date -s "$year-$month-$day $hour:$min:$sec" &>/dev/null; then
        return 1
    fi
    return 0
}

while ! enter_time_and_change; do
    echo "Could not set the date to $year-$month-$day $hour:$min:$sec"
    read -rp "Try again? [Y/n]: " try_again_confirm
    if [ "${try_again_confirm^^}" = N ]; then
            exit 1
    fi
    echo
done

hwclock -w
echo "The system date has been sucessfully set to $year-$month-$day $hour:$min:$sec"
echo

echo "Press Enter to return to the menu"
echo
read -r nothing

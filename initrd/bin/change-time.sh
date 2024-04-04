#!/bin/bash
#change time using hwclock and date -s

clear

echo -e -n "Please enter the date and time you wish to set\n"
echo -e -n "enter the year please (4)\n"
read -n 4 year
echo -e "\n"
echo -e -n "enter the month please (2)\n"
read -n 2 month
echo -e "\n"
echo -e -n "enter the day please (2)\n"
read -n 2 day
echo -e "\n"
echo -e -n "enter the hour please (2)\n"
read -n 2 hour
echo -e "\n"
echo -e -n "enter minute please (2)\n"
read -n 2 min
echo -e "\n"
echo -e -n "enter second please (2)\n"
read -n 2 sec
echo -e "\n"

##getting the output of date -s 
OUTPUT=$(date -s "$year-$month-$day $hour:$min:$sec" 2>&1)


##if output is starting with the letter d which is the beginning of the error message then we do the script again 
if [[ ${OUTPUT} == d* ]]; then
    echo "The date is not correct, press any key to set it again"
    echo -e "\n"
    read -n 1 noting
    clear
    change-time.sh
else
    hwclock -w
    echo -e "the date as been sucessfully set to $year-$month-$day $hour:$min:$sec"
    echo -e "\n"

    echo -e "press any key to return to the menu"
    echo -e "\n"
    read -n 1 nothing
    
fi

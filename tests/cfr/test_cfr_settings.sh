#!/bin/bash

set -e -o pipefail

repo_root=$(cd "$(dirname "$0")/../.." && pwd)
test_root=$(mktemp -d "$repo_root/.cfr-test.XXXXXX")
trap 'rm -rf "$test_root"' EXIT
attributes=$test_root/sys/class/firmware-attributes/coreboot-cfr/attributes
mkdir -p "$attributes"

printf '%s\n' '#!/bin/bash' >"$test_root/functions.sh"

make_enum() {
	local name=$1 display=$2 current=$3 default=$4 values=$5 mode=${6:-644}
	local dir=$attributes/$name
	mkdir -p "$dir"
	printf '%s\n' enumeration >"$dir/type"
	printf '%s\n' "$display" >"$dir/display_name"
	printf '%s\n' "$current" >"$dir/current_value"
	printf '%s\n' "$default" >"$dir/default_value"
	printf '%s\n' "$values" >"$dir/possible_values"
	chmod "$mode" "$dir/current_value"
}

make_integer() {
	local name=$1 display=$2 current=$3 default=$4 minimum=$5 maximum=$6 step=$7 mode=${8:-644}
	local dir=$attributes/$name
	mkdir -p "$dir"
	printf '%s\n' integer >"$dir/type"
	printf '%s\n' "$display" >"$dir/display_name"
	printf '%s\n' "$current" >"$dir/current_value"
	printf '%s\n' "$default" >"$dir/default_value"
	printf '%s\n' "$minimum" >"$dir/min_value"
	printf '%s\n' "$maximum" >"$dir/max_value"
	printf '%s\n' "$step" >"$dir/scalar_increment"
	chmod "$mode" "$dir/current_value"
}

make_enum mode 'Performance mode' 'Balanced mode' 'Balanced mode' 'Balanced mode;Performance mode'
make_enum feature 'Optional feature' off off 'off;on' 444
make_integer number 'Fan limit' 50 50 10 100 5
make_enum readonly 'Read only' locked locked locked 444
make_enum missing 'Disappearing setting' old old 'old;new'
make_enum error 'Write error setting' old old 'old;new'
make_enum malformed 'Malformed setting' A A 'A;;B'
make_enum trailing_empty 'Trailing empty enum' A A 'A;'
make_enum trailing_lines 'Trailing metadata lines' A A 'A;B'
printf 'enumeration\n\n' >"$attributes/trailing_lines/type"
make_enum invalid_default 'Invalid default setting' A C 'A;B'
make_integer expression_range 'Expression range' 5 5 '1+2' 10 1
make_integer oversized_range 'Oversized range' 5 5 0 99999999999999999999 1
make_enum inactive 'Inactive setting' off off 'off;on'
printf '%s\n' inactive >"$attributes/inactive/flags"
make_enum suppressed 'Suppressed setting' off off 'off;on'
printf '%s\n' suppressed >"$attributes/suppressed/flags"
make_enum flagged_readonly 'Flagged read only' off off 'off;on'
printf '%s\n' readonly >"$attributes/flagged_readonly/flags"
make_enum flagged_volatile 'Flagged volatile' off off 'off;on'
printf '%s\n' volatile >"$attributes/flagged_volatile/flags"
make_enum cancelled 'Cancelled setting' old old 'old;new'
printf '%s\n' 1 >"$attributes/pending_reboot"
printf '%s\n' 0 >"$test_root/state"
chmod -R a+rwX "$test_root"
chmod 444 "$attributes/feature/current_value" "$attributes/readonly/current_value"

cat >"$test_root/gui_functions.sh" <<'EOF'
#!/bin/bash
whiptail_type() { "${WHIPTAIL_BIN:?}" "$@"; }
whiptail_error() { "${WHIPTAIL_BIN:?}" "$@"; }
EOF

cat >"$test_root/whiptail" <<'EOF'
#!/bin/bash
set -e
root=${CFR_TEST_ROOT:?}
state=${CFR_TEST_STATE:?}
count=$(cat "$state")
count=$((count + 1))
printf '%s\n' "$count" >"$state"
printf '%s\t%s\n' "$count" "$*" >>"$root/whiptail.log"
kind=
for arg in "$@"; do
	case "$arg" in
		--menu) kind=menu ;;
		--inputbox) kind=input ;;
		--yesno) kind=yesno ;;
	esac
done
if [ "$kind" = menu ]; then
	case "$count" in
		1)
			# fbwhiptail writes terminal cursor controls to stdout.
			printf '\033[?25l\033[?25h'
			case " $* " in
				*' inactive '*|*' suppressed '*|*' malformed '*|*' trailing_empty '*|\
				*' trailing_lines '*|\
				*' invalid_default '*|*' expression_range '*|*' oversized_range '*) exit 1 ;;
			esac
			printf '%s\n' mode >&2
			;;
		2) printf '%s\n' 'Performance mode' >&2 ;;
		5) printf '%s\n' number >&2 ;;
		9) printf '%s\n' cancelled >&2 ;;
		10) printf '%s\n' new >&2 ;;
		12) printf '%s\n' readonly >&2 ;;
		14) rm -rf "$root/sys/class/firmware-attributes/coreboot-cfr/attributes/missing"; printf '%s\n' missing >&2 ;;
		16) printf '%s\n' error >&2 ;;
		17) printf '%s\n' new >&2 ;;
		20) printf '%s\n' flagged_volatile >&2 ;;
		*) exit 1 ;;
	esac
elif [ "$kind" = input ]; then
	printf '%s\n' 75 >&2
elif [ "$kind" = yesno ]; then
	printf '%s' "$*" >"$root/last_confirmation"
	case "$count" in
		3|7) exit 0 ;;
		18)
			rm -f "$root/sys/class/firmware-attributes/coreboot-cfr/attributes/error/current_value"
			ln -s /dev/full "$root/sys/class/firmware-attributes/coreboot-cfr/attributes/error/current_value"
			exit 0
			;;
		11) exit 1 ;;
		*) exit 1 ;;
	esac
fi
case " $* " in
	*' The firmware rejected the setting write. '*)
		rm -f "$root/sys/class/firmware-attributes/coreboot-cfr/attributes/error/current_value"
		printf '%s\n' old >"$root/sys/class/firmware-attributes/coreboot-cfr/attributes/error/current_value"
		printf '%s\n' seen >"$root/write_error_seen"
		;;
esac
if [ "$count" -eq 2 ]; then
	chmod 644 "$root/sys/class/firmware-attributes/coreboot-cfr/attributes/feature/current_value"
	printf '%s\n' on >"$root/sys/class/firmware-attributes/coreboot-cfr/attributes/feature/current_value"
	chmod 644 "$root/sys/class/firmware-attributes/coreboot-cfr/attributes/feature/current_value"
fi
exit 0
EOF
chmod +x "$test_root/whiptail"

WHIPTAIL_BIN="$test_root/whiptail" CFR_TEST_ROOT="$test_root" CFR_TEST_STATE="$test_root/state" \
	"$repo_root/initrd/bin/cfr-settings.sh" --test-root "$test_root"

[ "$(cat "$attributes/mode/current_value")" = 'Performance mode' ]
[ "$(cat "$attributes/number/current_value")" = 75 ]
[ "$(cat "$attributes/feature/current_value")" = on ]
[ "$(cat "$attributes/cancelled/current_value")" = old ]
[ "$(grep -c '^Current: old$' "$test_root/last_confirmation")" -eq 1 ]
[ "$(grep -c '^Requested: new$' "$test_root/last_confirmation")" -eq 1 ]
[ -w "$attributes/feature/current_value" ]
[ -e "$attributes/malformed/current_value" ]
[ -e "$attributes/trailing_empty/current_value" ]
[ -e "$attributes/trailing_lines/current_value" ]
[ -e "$attributes/invalid_default/current_value" ]
[ -e "$attributes/expression_range/current_value" ]
[ -e "$attributes/oversized_range/current_value" ]
[ -e "$test_root/write_error_seen" ] || {
	cat "$test_root/whiptail.log" >&2
	false
}
[ "$(cat "$attributes/error/current_value")" = old ]
[ "$(cat "$attributes/flagged_volatile/current_value")" = off ]
grep -q 'flagged_volatile.*\[read-only\] \[volatile\]' "$test_root/whiptail.log"
grep -q 'Firmware reports that a reboot is pending.' "$test_root/whiptail.log"
printf '%s\n' 'CFR settings fixture passed'

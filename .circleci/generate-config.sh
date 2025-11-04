#!/bin/bash -e

board_list=$(mktemp)
cb_board_list=$(mktemp)

ls -w1 ./boards/ > $board_list

coreboot_versions=$(grep -R "CONFIG_COREBOOT_VERSION=" ./boards | rev | cut -d'=' -f1 | rev | sort | uniq)

while IFS="" read -r cb_ver; do
  cb_board=$(grep -R -m1 "CONFIG_COREBOOT_VERSION=$cb_ver" ./boards | head -n1 | cut -d'/' -f3)
  echo "$cb_ver $cb_board" >> "$cb_board_list"
  sed -i "/^${cb_board}*$/d" "$board_list"
done <<< "$coreboot_versions"

function get_arch_for_board() {
  local board="$1"

  if grep "CONFIG_TARGET_ARCH" "./boards/${board}/${board}.config" >/dev/null 2>&1; then
    echo $(cat "./boards/${board}/${board}.config" | grep "CONFIG_TARGET_ARCH=" | cut -d'=' -f2)
  else
    echo "x86"
  fi
}

function print_cb_board() {
  local cb_ver=$(echo "$1" | cut -d' ' -f1)
  local board=$(echo "$1" | cut -d' ' -f2)
  local arch=$(get_arch_for_board "$board")

  cat << EOF
      # Coreboot: $cb_ver
      - build_and_persist:
          name: $board
          arch: $arch
          target: $board
          subcommand: ""
          requires:
            - prep_env

EOF
}

function print_board() {
  local board="$1"
  local cb_ver=$(cat "./boards/${board}/${board}.config" | grep "CONFIG_COREBOOT_VERSION=" | cut -d'=' -f2)
  local parent_board=$(cat $cb_board_list | grep "$cb_ver " | cut -d' ' -f2)
  local arch=$(get_arch_for_board "$board")

  cat << EOF
      - build:
          name: $board
          arch: $arch
          target: $board
          subcommand: ""
          requires:
            - $parent_board    # Coreboot: $cb_ver

EOF
}

cat ./.circleci/template-config.yml

while IFS="" read -r board; do
  print_cb_board "$board"
done <<<$(cat $cb_board_list)

while IFS="" read -r board; do
  print_board "$board"
done <<<$(cat $board_list)



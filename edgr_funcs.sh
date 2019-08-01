#!/bin/bash

# Turns number of seconds into human readable output like:
# 5h 4m 23s
sec_to_human() {
  secs=$1

  output=''

  if ! [[ "$secs" =~ ^[0-9]+$ ]]; then
    printf "input: '%s' is not a number\n" "$secs" >&2
    exit
  fi

  if [[ $secs -ge $((365*24*60*60)) ]]; then
    years=$((secs / (365*24*60*60)))
    output="$output ${years}y"
    secs=$((secs - ($years*365*24*60*60)))
  fi

  if [[ $secs -ge $((24*60*60)) ]]; then
    days=$((secs / (24*60*60)))
    output="$output ${days}d"
    secs=$((secs - ($days*24*60*60)))
  fi

  if [[ $secs -ge $((60*60)) ]]; then
    hours=$((secs / (60*60)))
    output="$output ${hours}h"
    secs=$((secs - ($hours*60*60)))
  fi

  if [[ $secs -ge 60 ]]; then
    mins=$((secs / 60))
    output="$output ${mins}m"
    secs=$((secs - ($mins*60)))
  fi

  output="$output ${secs}s"

  echo $output
}

random_pics() {
  src=$1
  dst=$2
  count=$3
  prefix=$4

  shopt -s nullglob
  images=( "$src"/*.{jpeg,jpg,png,gif} )
  shopt -u nullglob

  # Make sure we have enough images as requested
  while [[ ${#images[@]} -lt "$count" ]]; do
    images=( ${images[@]} ${images[@]} )
  done

  # Shuffle the array
  images=( $( shuf -n $count -e "${images[@]}" ) )

  # Select $count images at random from the pool available

  counter=0
  for image in ${images[@]}; do
    counter=$((counter+1))
    # Grab the file's extension
    suffix="${image##*.}"

    new_file="$(printf "%s-%08i" "$prefix" "$counter")"
    # Check to see if image is worth points, and save value
    points=$(echo "$image" | grep -Eo '[0-9]+pts' | sed -e 's/pts$//')

    if [[ "$points" =~ ^[0-9]+$ ]] && [[ "$points" -gt 0 ]]; then
      new_file="$new_file-${points}pts"
    fi

    new_file="$new_file.$suffix"

    echo cp "$image" "$dst/$new_file"
  done
}

random_pic_playlist() {
  src=$1
  count=$2

  shopt -s nullglob
  images=( "$src"/*.{jpeg,jpg,png,gif} )
  shopt -u nullglob

  # Make sure we have enough images as requested
  while [[ ${#images[@]} -lt "$count" ]]; do
    images=( ${images[@]} ${images[@]} )
  done

  # Shuffle the array
  images=( $( shuf -n $count -e "${images[@]}" ) )

  for image in ${images[@]}; do
    echo "$image"
  done
}

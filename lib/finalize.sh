#!/bin/sh
# Runs after an export and prints the path of the final PNG on stdout.
#   $1  exported image: PNG, or PPM when $6 names an encoder
#   $2  non-empty to keep a copy
#   $3  directory for the copy; empty for <Pictures>/Screenshots
#   $4  notification body; empty for no notification
#   $5  failure message; the directory is appended
#   $6  PPM to PNG encoder: ffmpeg or magick
src=$1 save=$2 dir=$3 body=$4 fail=$5 encoder=$6
app="Screenshot+"

notify() { dms notify "$app" "$@" --app "$app" --icon screenshot_region; }

png=$src
case $src in
*.ppm)
    png=${src%.ppm}.png
    case $encoder in
    ffmpeg) ffmpeg -loglevel error -y -i "$src" -compression_level 1 "$png" ;;
    *) magick "$src" -define png:compression-level=1 "$png" ;;
    esac || exit 1
    rm -f -- "$src"
    ;;
esac

if [ -n "$save" ]; then
    [ -n "$dir" ] || dir="$(xdg-user-dir PICTURES 2>/dev/null || printf %s "$HOME/Pictures")/Screenshots"
    dest="$dir/screenshot-$(date +%Y%m%d-%H%M%S).png"
    if mkdir -p -- "$dir" && cp -- "$png" "$dest"; then
        [ -z "$body" ] || notify "$body" --file "$dest"
    else
        notify "$fail $dir"
    fi
elif [ -n "$body" ]; then
    notify "$body"
fi

printf '%s\n' "$png"

#!/bin/sh
# Runs detached after an export so the overlay can close immediately.
#   $1  exported PNG (temporary, removed at the end)
#   $2  non-empty to keep a copy
#   $3  directory for the copy; empty for <Pictures>/Screenshots
#   $4  notification body; empty for no notification
#   $5  failure message; the directory is appended
src=$1 save=$2 dir=$3 body=$4 fail=$5
app="Screenshot+"

notify() { dms notify "$app" "$@" --app "$app" --icon screenshot_region; }

if [ -n "$save" ]; then
    [ -n "$dir" ] || dir="$(xdg-user-dir PICTURES 2>/dev/null || printf %s "$HOME/Pictures")/Screenshots"
    dest="$dir/screenshot-$(date +%Y%m%d-%H%M%S).png"
    if mkdir -p -- "$dir" && cp -- "$src" "$dest"; then
        [ -z "$body" ] || notify "$body" --file "$dest"
    else
        notify "$fail $dir"
    fi
elif [ -n "$body" ]; then
    notify "$body"
fi

# The clipboard and the notification daemon read the file asynchronously.
sleep 10
rm -f -- "$src"

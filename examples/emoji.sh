#!/bin/sh
# Example Blink plugin. Copy to ~/.config/blink/plugins/ and type "emoji <word>".
# The query arrives as $1; print a JSON list of items.
q=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
out=""
while IFS='|' read -r name char; do
  case "$name" in *"$q"*) out="$out{\"title\":\"$char  $name\",\"subtitle\":\"Copy to clipboard\",\"copy\":\"$char\"}," ;; esac
done <<LIST
thumbs up|👍
tick|✅
fire|🔥
rocket|🚀
laugh|😂
heart|❤️
eyes|👀
party|🎉
thinking|🤔
shrug|🤷
LIST
printf '{"items":[%s]}\n' "${out%,}"

#!/usr/bin/env bash
# Build the portable-player copy of the music library.
#
# WHAT THIS IS FOR
# The archive holds whatever the indexers actually delivered. The portable
# player is an 80 MHz device whose DAC does 44.1 kHz only, with a ~5 MB/s USB
# stack and a fixed-size card. This mirrors the archive into a tree that suits
# it: MP3 V0, forced to 44.1 kHz, ReplayGain-tagged in album mode, cover art
# capped small.
#
# THIS IS THE ENFORCEMENT POINT, NOT A SAFETY NET.
# Lidarr parses quality from the release NAME at search time and from file
# CONTENT at import time. A release named "Artist-Album.1994" with no hi-res
# token passes a profile that excludes 24-bit, and turns out to be 24/96. That
# is not a misconfiguration and no name-based rule can prevent it. The `-ar
# 44100` below is the only thing that reliably keeps hi-res off the device.
#
# Two rules, deliberately:
#   lossless source -> encode to MP3 V0 at 44.1 kHz
#   lossy source    -> copy through, because re-encoding lossy to lossy is a
#                      second generation of loss for no benefit
#
# Decisions are made on the CODEC reported by ffprobe, not the file extension:
# .m4a is ALAC (lossless) or AAC (lossy) and only the codec knows which.
set -uo pipefail

SRC_DIRS=(${SRC_DIRS:-/music /music-manual})
DEST="${DEST:-/music-ipod}"
INTERVAL="${INTERVAL:-600}"
LAME_Q="${LAME_Q:-0}"                 # libmp3lame -q:a 0 == LAME V0, ~245 kbps
ART_MAX="${ART_MAX:-200}"             # px, long edge
TEXTFILE="${TEXTFILE:-}"              # optional prometheus textfile path

LOSSLESS_CODECS=" flac alac ape wavpack tta shorten pcm_s16le pcm_s24le pcm_s32le "

log() { printf '%s %s\n' "$(date -u +%FT%TZ)" "$*"; }

# FAT32 rejects these outright, and trailing dots/spaces break on it too.
sanitize() { printf '%s' "$1" | tr ':?*<>|"\\' '-------' | sed -e 's/[. ]\+$//'; }

# Map a source path to its destination path, component by component, swapping
# the extension to .mp3 for anything we will encode.
dest_for() {
  local src="$1" root="$2" ext="$3" rel out=""
  rel="${src#"$root"/}"
  local IFS=/ part
  for part in $rel; do out="$out/$(sanitize "$part")"; done
  out="$DEST$out"
  [ -n "$ext" ] && out="${out%.*}.$ext"
  printf '%s' "$out"
}

codec_of() {
  ffprobe -v error -select_streams a:0 -show_entries stream=codec_name \
          -of default=nw=1:nk=1 "$1" 2>/dev/null | head -1
}

# Cover art: prefer a real image file (Lidarr imports them via Import Extra
# Files), fall back to the picture embedded in the first track. Rockbox is set
# to "prefer image file", and embedded art would only waste card space, so the
# encoder drops it with -vn.
make_cover() {
  local sdir="$1" ddir="$2" img="" t
  for n in cover.jpg cover.jpeg folder.jpg front.jpg cover.png folder.png; do
    [ -f "$sdir/$n" ] && { img="$sdir/$n"; break; }
  done
  if [ -z "$img" ]; then
    t=$(find "$sdir" -maxdepth 1 -type f \( -iname '*.flac' -o -iname '*.mp3' -o -iname '*.m4a' \) | sort | head -1)
    [ -n "$t" ] || return 0
    ffmpeg -nostdin -v error -y -i "$t" -an -frames:v 1 "$ddir/.cover.src.jpg" 2>/dev/null || return 0
    [ -s "$ddir/.cover.src.jpg" ] || { rm -f "$ddir/.cover.src.jpg"; return 0; }
    img="$ddir/.cover.src.jpg"
  fi
  magick "$img" -resize "${ART_MAX}x${ART_MAX}>" "$ddir/cover.jpg" 2>/dev/null \
    || convert "$img" -resize "${ART_MAX}x${ART_MAX}>" "$ddir/cover.jpg" 2>/dev/null
  rm -f "$ddir/.cover.src.jpg"
}

run_once() {
  local start end converted=0 copied=0 errors=0 albums=0
  start=$(date +%s)
  local expected changed
  expected=$(mktemp); changed=$(mktemp)

  for root in "${SRC_DIRS[@]}"; do
    [ -d "$root" ] || continue
    while IFS= read -r src; do
      case "$(basename "$src")" in ._*|.DS_Store) continue ;; esac
      case "${src,,}" in
        *.nfo|*.sfv|*.m3u|*.m3u8|*.cue|*.log|*.txt|*.md5|*.accurip) continue ;;
        *.jpg|*.jpeg|*.png) continue ;;   # handled by make_cover
      esac

      local codec lossless=0 dst
      codec=$(codec_of "$src")
      [ -n "$codec" ] || continue                      # not audio
      [[ "$LOSSLESS_CODECS" == *" $codec "* ]] && lossless=1

      if [ "$lossless" = 1 ]; then dst=$(dest_for "$src" "$root" mp3)
      else dst=$(dest_for "$src" "$root" ""); fi
      printf '%s\n' "$dst" >> "$expected"

      # Skip when the destination is already newer than its source.
      [ -f "$dst" ] && [ "$dst" -nt "$src" ] && continue

      mkdir -p "$(dirname "$dst")"
      if [ "$lossless" = 1 ]; then
        # -nostdin is mandatory: inside a read loop ffmpeg otherwise consumes
        # the file list from stdin and corrupts every later path.
        # -ar 44100 is the hi-res guard described at the top of this file.
        # -vn drops embedded art; cover.jpg carries it instead.
        if ffmpeg -nostdin -v error -y -i "$src" \
             -vn -map_metadata 0 -map a:0 \
             -c:a libmp3lame -q:a "$LAME_Q" -ar 44100 \
             -id3v2_version 3 "$dst" 2>/dev/null; then
          converted=$((converted + 1))
        else
          errors=$((errors + 1)); rm -f "$dst"; log "ERROR encoding $src"; continue
        fi
      else
        cp -f "$src" "$dst" && copied=$((copied + 1)) || { errors=$((errors+1)); continue; }
      fi
      printf '%s\n' "$(dirname "$src")|$(dirname "$dst")" >> "$changed"
    done < <(find "$root" -type f 2>/dev/null)
  done

  # Cover art + ReplayGain, once per album that actually changed. rsgain runs in
  # album mode so relative levels between albums are preserved, which is the
  # entire point of ReplayGain for whole-album listening.
  if [ -s "$changed" ]; then
    while IFS='|' read -r sdir ddir; do
      albums=$((albums + 1))
      make_cover "$sdir" "$ddir"
      mapfile -t mp3s < <(find "$ddir" -maxdepth 1 -type f -iname '*.mp3' 2>/dev/null)
      [ "${#mp3s[@]}" -gt 0 ] && rsgain custom -a -s i -c p -I 3 "${mp3s[@]}" >/dev/null 2>&1
    done < <(sort -u "$changed")
  fi

  # Prune: anything in the destination that no source still maps to. cover.jpg
  # is generated here rather than mirrored, so it is never a prune candidate.
  while IFS= read -r f; do
    case "$(basename "$f")" in cover.jpg) continue ;; esac
    grep -qxF "$f" "$expected" || { rm -f "$f"; log "pruned $f"; }
  done < <(find "$DEST" -type f 2>/dev/null)
  find "$DEST" -mindepth 1 -type d -empty -delete 2>/dev/null

  rm -f "$expected" "$changed"
  end=$(date +%s)
  log "run: converted=$converted copied=$copied albums=$albums errors=$errors in $((end-start))s"

  if [ -n "$TEXTFILE" ]; then
    local tmp; tmp=$(mktemp "$TEXTFILE.XXXXXX")
    {
      echo '# HELP music_transcode_last_run_timestamp_seconds Unix time of the last transcode pass.'
      echo '# TYPE music_transcode_last_run_timestamp_seconds gauge'
      echo "music_transcode_last_run_timestamp_seconds $end"
      echo '# HELP music_transcode_last_duration_seconds Duration of the last transcode pass.'
      echo '# TYPE music_transcode_last_duration_seconds gauge'
      echo "music_transcode_last_duration_seconds $((end-start))"
      echo '# HELP music_transcode_files_converted Files encoded to MP3 in the last pass.'
      echo '# TYPE music_transcode_files_converted gauge'
      echo "music_transcode_files_converted $converted"
      echo '# HELP music_transcode_files_copied Lossy files copied through unchanged in the last pass.'
      echo '# TYPE music_transcode_files_copied gauge'
      echo "music_transcode_files_copied $copied"
      echo '# HELP music_transcode_errors Files that failed in the last pass.'
      echo '# TYPE music_transcode_errors gauge'
      echo "music_transcode_errors $errors"
    } > "$tmp"
    chmod 644 "$tmp"; mv "$tmp" "$TEXTFILE"
  fi
}

log "music-transcode starting: src=${SRC_DIRS[*]} dest=$DEST interval=${INTERVAL}s q=V$LAME_Q"
while :; do
  run_once
  [ "$INTERVAL" = "0" ] && break
  sleep "$INTERVAL"
done

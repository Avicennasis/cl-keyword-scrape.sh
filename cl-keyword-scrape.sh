#!/usr/bin/env bash
# cl-keyword-scrape.sh
#
# Scrape Craigslist search results, fetch each posting, and print matches for a keyword regex.
#
# Parsing backend (auto-detected):
#   - htmlq (preferred): https://github.com/mgdm/htmlq
#   - pup:              https://github.com/ericchiang/pup
#   - hxselect stack:   hxnormalize + hxselect (package: html-xml-utils)
#
# Example:
#   ./cl-keyword-scrape.sh --city pittsburgh --section gms --pages 2 --step 100 \
#     --regex 'mario|ps[34]|xbox|gameboy|linux|sega|brewing|books|guitar' --output results.txt

set -Eeuo pipefail
IFS=$'\n\t'

VERSION="1.1.0"

CITY="pittsburgh"
SECTION="gms"
PAGES=2
STEP=100
START=0
SORT="date"
QUERY=""
REGEX='mario|ps[34]|xbox|gameboy|linux|sega|brewing|books|guitar'
OUTPUT="results.txt"
APPEND=0
DELAY=2
TIMEOUT=20
RETRIES=3
USER_AGENT="cl-keyword-scrape/${VERSION} (curl)"
FORMAT="block"       # plain | tsv
PRINT_URLS_ONLY=0
VERBOSE=0
PARSER="auto"        # auto | htmlq | pup | hx

TMPDIR=""

usage() {
  cat <<'EOF'
Usage:
  cl-keyword-scrape.sh [options]

Options:
  --city NAME              Craigslist city subdomain (default: pittsburgh)
  --section NAME           Section path (default: gms)
  --pages N                Number of pages to fetch (default: 2)
  --start N                Starting offset (default: 0)
  --step N                 Offset step per page (default: 100)
  --sort VALUE             Sort order (default: date)
  --query TEXT             Craigslist query parameter (default: empty)
  --regex REGEX            Extended regex to match (default: mario|ps[34]|xbox|...)
  --output FILE            Output file (default: results.txt)
  --append                 Append to output file (default: overwrite)
  --format plain|tsv        Output format (default: plain)
  --print-urls             Only print the unique URLs found (do not fetch posts)
  --delay SECONDS          Delay between HTTP requests (default: 2)
  --timeout SECONDS        curl timeout (default: 20)
  --retries N              curl retries (default: 3)
  --user-agent STRING      User-Agent header (default: script name/version)
  --parser auto|htmlq|pup|hx  Parsing backend (default: auto)
  --verbose                Verbose logging to stderr
  --version                Print version
  -h, --help               Show help

Output formats:
  plain:  Match! (hit1)(hit2) URL - Title
  tsv:    Match! <TAB> (hit1)(hit2) <TAB> URL <TAB> Title

Exit codes:
  0 success, 1 usage/dependency error, 2 runtime/network error
EOF
}

log() {
  if [[ "$VERBOSE" -eq 1 ]]; then
    printf '[%s] %s\n' "$(date +'%Y-%m-%d %H:%M:%S')" "$*" >&2
  fi
}

die_usage() {
  printf 'Error: %s\n' "$*" >&2
  usage >&2
  exit 1
}

die() {
  printf 'Error: %s\n' "$*" >&2
  exit 2
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die_usage "Missing dependency: $1"
}

cleanup() {
  local rc=$?
  [[ -n "${TMPDIR:-}" && -d "${TMPDIR:-}" ]] && rm -rf "$TMPDIR"
  exit "$rc"
}

trap cleanup EXIT
trap 'printf "\nInterrupted.\n" >&2; exit 2' INT TERM

urlencode() {
  local s="${1:-}" out="" c hex i
  for (( i=0; i<${#s}; i++ )); do
    c="${s:i:1}"
    case "$c" in
      [a-zA-Z0-9.~_-]) out+="$c" ;;
      ' ') out+='%20' ;;
      *) printf -v hex '%%%02X' "'$c"; out+="$hex" ;;
    esac
  done
  printf '%s' "$out"
}

fetch() {
  local url="$1"
  curl \
    --fail --silent --show-error --location \
    --max-time "$TIMEOUT" \
    --retry "$RETRIES" --retry-delay 1 --retry-all-errors \
    -H "User-Agent: ${USER_AGENT}" \
    "$url"
}

build_search_url() {
  local offset="$1"
  local base="https://${CITY}.craigslist.org/search/${SECTION}"
  local qs="s=${offset}&sort=$(urlencode "$SORT")"
  if [[ -n "$QUERY" ]]; then
    qs="${qs}&query=$(urlencode "$QUERY")"
  fi
  printf '%s?%s' "$base" "$qs"
}

abs_url() {
  local u="$1"
  if [[ "$u" =~ ^https?:// ]]; then
    printf '%s\n' "$u"
  elif [[ "$u" =~ ^/ ]]; then
    printf 'https://%s.craigslist.org%s\n' "$CITY" "$u"
  else
    printf 'https://%s.craigslist.org/%s\n' "$CITY" "$u"
  fi
}

select_parser() {
  case "$PARSER" in
    htmlq|pup|hx) ;;
    auto) ;;
    *) die_usage "Invalid --parser: $PARSER" ;;
  esac

  if [[ "$PARSER" == "auto" ]]; then
    if command -v htmlq >/dev/null 2>&1; then
      PARSER="htmlq"
    elif command -v pup >/dev/null 2>&1; then
      PARSER="pup"
    elif command -v hxselect >/dev/null 2>&1 && command -v hxnormalize >/dev/null 2>&1; then
      PARSER="hx"
    else
      die_usage "No HTML parser found. Install one of: htmlq, pup, or html-xml-utils (hxselect/hxnormalize)."
    fi
  else
    case "$PARSER" in
      htmlq) need_cmd htmlq ;;
      pup) need_cmd pup ;;
      hx) need_cmd hxselect; need_cmd hxnormalize; need_cmd lynx ;;
    esac
  fi

  log "Parser selected: $PARSER"
}

extract_listing_urls() {
  # Read HTML from stdin. Print one absolute listing URL per line.
  # Strategy: extract all <a href>, then filter to URLs that look like postings for the chosen section.
  # This is more resilient to Craigslist UI/class changes than relying on a specific class name.

  local pattern="/${SECTION}/(d/|[0-9]+\\.html)"

  case "$PARSER" in
    htmlq)
      htmlq --attribute href 'a' \
        | sed -e 's/[[:space:]]\+$//' -e '/^$/d' \
        | grep -E "$pattern" || true
      ;;
    pup)
      pup 'a attr{href}' \
        | sed -e 's/[[:space:]]\+$//' -e '/^$/d' \
        | grep -E "$pattern" || true
      ;;
    hx)
      hxnormalize -x \
        | hxselect -i -c -s $'\n' 'a::attr(href)' \
        | sed -e 's/[[:space:]]\+$//' -e '/^$/d' \
        | grep -E "$pattern" || true
      ;;
  esac \
  | while IFS= read -r u; do
      # Drop obviously bad/non-http links defensively
      [[ -n "$u" ]] || continue
      [[ "$u" =~ ^(javascript:|mailto:) ]] && continue
      abs_url "$u"
    done
}


extract_title() {
  # Read HTML from stdin. Print a single-line title.
  case "$PARSER" in
    htmlq)
      htmlq --text --ignore-whitespace 'span#titletextonly' \
        | head -n 1 \
        | tr -d '\r' \
        | sed -e 's/^[[:space:]]\+//' -e 's/[[:space:]]\+$//'
      ;;
    pup)
      pup 'span#titletextonly text{}' \
        | head -n 1 \
        | tr -d '\r' \
        | sed -e 's/^[[:space:]]\+//' -e 's/[[:space:]]\+$//'
      ;;
    hx)
      hxnormalize -x \
        | hxselect -i -c 'span#titletextonly' \
        | lynx -stdin -dump \
        | head -n 1 \
        | tr -d '\r' \
        | sed -e 's/^[[:space:]]\+//' -e 's/[[:space:]]\+$//'
      ;;
  esac
}

extract_body_text() {
  # Read HTML from stdin. Print body text (multi-line).
  case "$PARSER" in
    htmlq)
      htmlq --text --ignore-whitespace '#postingbody' \
        | tr -d '\r' \
        | sed -e '/^$/d' -e '/^QR Code Link to This Post$/d'
      ;;
    pup)
      pup '#postingbody text{}' \
        | tr -d '\r' \
        | sed -e '/^$/d' -e '/^QR Code Link to This Post$/d'
      ;;
    hx)
      hxnormalize -x \
        | hxselect -i -c '#postingbody' \
        | lynx -stdin -dump \
        | tr -d '\r' \
        | sed -e '/^$/d' -e '/^QR Code Link to This Post$/d'
      ;;
  esac
}

collect_hits() {
  # Args: content_string
  # Output: (hit1)(hit2)... (unique, case-insensitive). Returns nonzero if no hits.
  local content="$1"
  local hits=() line
  while IFS= read -r line; do
    hits+=("$line")
  done < <(printf '%s\n' "$content" | LC_ALL=C grep -Eoi "$REGEX" | awk '
    { k=tolower($0); if (!seen[k]++) print $0 }
  ')

  [[ "${#hits[@]}" -gt 0 ]] || return 1

  local out="" h
  for h in "${hits[@]}"; do out+="(${h})"; done
  printf '%s' "$out"
}

emit_match() {
  local hits="$1" url="$2" title="$3"
  case "$FORMAT" in
    plain)
      if [[ -n "$title" ]]; then
        printf 'Match! %s %s - %s\n' "$hits" "$url" "$title"
      else
        printf 'Match! %s %s\n' "$hits" "$url"
      fi
      ;;
    tsv)
      printf 'Match!\t%s\t%s\t%s\n' "$hits" "$url" "$title"
      ;;
    block)
      printf 'Match! %s\n' "$hits"
      printf 'URL:   %s\n' "$url"
      printf 'Title: %s\n' "$title"
      printf '\n'
      ;;
    *)
      die_usage "Unknown format: $FORMAT"
      ;;
  esac
}


main() {
  local opts
  if ! opts=$(getopt -o h --long \
    help,version,city:,section:,pages:,start:,step:,sort:,query:,regex:,output:,append,format:,print-urls,delay:,timeout:,retries:,user-agent:,parser:,verbose \
    -n 'cl-keyword-scrape.sh' -- "$@"); then
    usage >&2
    exit 1
  fi
  eval set -- "$opts"

  while true; do
    case "$1" in
      --city) CITY="$2"; shift 2 ;;
      --section) SECTION="$2"; shift 2 ;;
      --pages) PAGES="$2"; shift 2 ;;
      --start) START="$2"; shift 2 ;;
      --step) STEP="$2"; shift 2 ;;
      --sort) SORT="$2"; shift 2 ;;
      --query) QUERY="$2"; shift 2 ;;
      --regex) REGEX="$2"; shift 2 ;;
      --output) OUTPUT="$2"; shift 2 ;;
      --append) APPEND=1; shift ;;
      --format) FORMAT="$2"; shift 2 ;;
      --print-urls) PRINT_URLS_ONLY=1; shift ;;
      --delay) DELAY="$2"; shift 2 ;;
      --timeout) TIMEOUT="$2"; shift 2 ;;
      --retries) RETRIES="$2"; shift 2 ;;
      --user-agent) USER_AGENT="$2"; shift 2 ;;
      --parser) PARSER="$2"; shift 2 ;;
      --verbose) VERBOSE=1; shift ;;
      --version) printf '%s\n' "$VERSION"; exit 0 ;;
      -h|--help) usage; exit 0 ;;
      --) shift; break ;;
      *) break ;;
    esac
  done

  need_cmd curl
  need_cmd getopt
  need_cmd awk
  need_cmd sed
  need_cmd grep
  need_cmd sort
  need_cmd mktemp
  need_cmd wc
  need_cmd tee

  [[ "$PAGES" =~ ^[0-9]+$ ]] || die_usage "Invalid --pages: $PAGES"
  [[ "$START" =~ ^[0-9]+$ ]] || die_usage "Invalid --start: $START"
  [[ "$STEP" =~ ^[0-9]+$ ]] || die_usage "Invalid --step: $STEP"
  [[ "$DELAY" =~ ^[0-9]+([.][0-9]+)?$ ]] || die_usage "Invalid --delay: $DELAY"

  select_parser

  TMPDIR="$(mktemp -d)"
  local urls_file="${TMPDIR}/urls.txt"
  : > "$urls_file"

  log "Collecting URLs (city=$CITY section=$SECTION pages=$PAGES start=$START step=$STEP sort=$SORT query=$QUERY)"

  local i offset search_url html
  for (( i=0; i<PAGES; i++ )); do
    offset=$(( START + i * STEP ))
    search_url="$(build_search_url "$offset")"
    log "Fetching search page: $search_url"
    html="$(fetch "$search_url")" || die "Failed to fetch search page: $search_url"

    printf '%s' "$html" | extract_listing_urls >> "$urls_file"
    sleep "$DELAY"
  done

  sort -u -o "$urls_file" "$urls_file"
  
  local count
count="$(wc -l < "$urls_file" | tr -d ' ')"
log "Unique listing URLs: $count"
if [[ "$count" -eq 0 ]]; then
  die_usage "No listing URLs found. Craigslist markup likely changed; try --parser htmlq or update selectors."
fi


  if [[ "$PRINT_URLS_ONLY" -eq 1 ]]; then
    cat "$urls_file"
    exit 0
  fi

  if [[ "$APPEND" -eq 1 ]]; then : >> "$OUTPUT"; else : > "$OUTPUT"; fi

  log "Found $(wc -l < "$urls_file" | tr -d ' ') unique URLs. Fetching posts..."

  local url post_html title body content hits line
  while IFS= read -r url; do
    [[ -n "$url" ]] || continue
    log "Fetching post: $url"

    post_html="$(fetch "$url")" || { log "Fetch failed: $url"; sleep "$DELAY"; continue; }

    title="$(printf '%s' "$post_html" | extract_title)"
    body="$(printf '%s' "$post_html" | extract_body_text)"
    content="${title}"$'\n'"${body}"

    if hits="$(collect_hits "$content")"; then
      emit_match "$hits" "$url" "$title" | tee -a "$OUTPUT" >/dev/null
    fi

    sleep "$DELAY"
  done < "$urls_file"

  log "Done. Output: $OUTPUT"
}

main "$@"

# Craigslist Keyword Scraper (Bash)

A maintainable, public-friendly Bash CLI that searches a Craigslist section, fetches listings, and prints only the posts that match a user-supplied regex. It extracts the listing title and body text, highlights matched keywords, and writes organized results to an output file.

## Features

- Pure Bash implementation (no embedded Python parsing)
- Configurable search parameters (city, section, pages, offsets, sort, query)
- Configurable match regex (case-insensitive) with deduplicated hit reporting
- Multiple output formats (`plain`, `tsv`, `block`)
- Robust HTML parsing via an auto-detected backend:
  - `htmlq` (preferred, if installed)
  - `pup` (if installed)
  - `hxnormalize` + `hxselect` (`html-xml-utils`) with `lynx` fallback
- Network resiliency: retries, timeouts, redirects
- Rate limiting: configurable delay between requests
- Safe temp handling and cleanup via traps
- `--print-urls` mode to validate URL extraction without fetching posts

## Requirements

### Runtime
- Bash (4+ recommended)
- `curl`
- Common utilities: `getopt`, `awk`, `sed`, `grep`, `sort`, `mktemp`, `wc`, `tee`

### One HTML parsing option (required)
Choose one of the following:

1) **htmlq** (recommended)
- Install via Snap (Ubuntu):
  ```bash
  sudo snap install htmlq

2. **html-xml-utils** + lynx (good fallback, available via APT)

* Install via APT (Ubuntu):

  ```bash
  sudo apt update
  sudo apt install -y html-xml-utils lynx
  ```

3. **pup**

* Install via your preferred method (package manager or releases).

  * Project: [https://github.com/ericchiang/pup](https://github.com/ericchiang/pup)

## Installation

1. Put the script in your repo, for example:

   ```bash
   curl -LO https://example.com/cl-keyword-scrape.sh
   chmod +x cl-keyword-scrape.sh
   ```

2. Install dependencies (see Requirements).

3. Run:

   ```bash
   ./cl-keyword-scrape.sh --help
   ```

## Usage

```bash
./cl-keyword-scrape.sh [options]
```

### Common options

* `--city NAME`
  Craigslist city subdomain (default: `pittsburgh`)

* `--section NAME`
  Section path (default: `gms`)

* `--pages N`
  Number of pages to fetch (default: `2`)

* `--start N` / `--step N`
  Offset control for pagination (defaults: `0` and `100`)

* `--sort VALUE`
  Sort order (default: `date`)

* `--query TEXT`
  Craigslist query parameter (default: empty)

* `--regex REGEX`
  Extended regex used for matches (default includes examples like `mario|ps[34]|xbox|...`)

* `--output FILE` / `--append`
  Output file path (default: `results.txt`) and whether to append

* `--format plain|tsv|block`
  Output formatting (default: `plain` unless you changed it)

* `--delay SECONDS`
  Delay between HTTP requests (default: `2`)

* `--timeout SECONDS` / `--retries N`
  Network controls (defaults: `20` and `3`)

* `--parser auto|htmlq|pup|hx`
  Force a specific HTML parser backend (default: `auto`)

* `--print-urls`
  Only print the unique listing URLs discovered (does not fetch posts)

* `--verbose`
  Verbose logs to stderr

## Examples

### 1) Default behavior (two pages of Pittsburgh garage sales)

```bash
./cl-keyword-scrape.sh
```

### 2) Match a simple keyword

```bash
./cl-keyword-scrape.sh --pages 1 --regex 'sale'
```

### 3) Use a Craigslist query and a separate match regex

```bash
./cl-keyword-scrape.sh --query "guitar" --regex 'fender|gibson|martin'
```

### 4) Print URLs only (debug URL extraction)

```bash
./cl-keyword-scrape.sh --verbose --print-urls | head
```

### 5) TSV output for downstream processing

```bash
./cl-keyword-scrape.sh --format tsv --output results.tsv
```

### 6) Human-friendly multi-line “block” output

```bash
./cl-keyword-scrape.sh --format block --output results.txt
```

### 7) Be more conservative with rate limiting

```bash
./cl-keyword-scrape.sh --delay 3 --timeout 30 --retries 2
```

## Output Formats

### plain

One line per match:

```
Match! (Sale)(PS4) https://... - Listing Title
```

### tsv

Tab-delimited:

```
Match!    (Sale)(PS4)    https://...    Listing Title
```

### block

Multi-line record per match:

```
Match! (Sale)(PS4)
URL:   https://...
Title: Listing Title
```

## How It Works

1. Builds Craigslist search URLs using `--city`, `--section`, pagination offsets, and optional `--query`.
2. Fetches each search page with `curl`.
3. Extracts all anchor `href` values and filters them to listing URLs for the selected section.
4. Fetches each listing page and extracts:

   * Title (`#titletextonly`)
   * Body text (`#postingbody`)
5. Runs a case-insensitive regex match and prints only matched listings.
6. Writes output to the file specified by `--output`.

## Troubleshooting

### “Missing dependency” errors

Install the missing tool(s) listed. For HTML parsing, you must have at least one backend available:

* `htmlq` or `pup` or `hxselect` + `hxnormalize` (and `lynx` for the `hx` backend).

### No listing URLs found

* Run:

  ```bash
  ./cl-keyword-scrape.sh --verbose --print-urls
  ```
* If it prints `Unique listing URLs: 0`, Craigslist markup may have changed again, or your section/city may be incorrect.
* Try forcing a different parser backend:

  ```bash
  ./cl-keyword-scrape.sh --parser htmlq --verbose --print-urls
  ./cl-keyword-scrape.sh --parser hx --verbose --print-urls
  ```

### Empty results even though you expect matches

* Confirm your regex:

  ```bash
  ./cl-keyword-scrape.sh --pages 1 --regex 'sale' --verbose
  ```
* Use `--format block` to review what title text is being extracted.

### Requests failing or timing out

* Increase timeouts and delay, reduce retries if needed:

  ```bash
  ./cl-keyword-scrape.sh --timeout 45 --delay 3 --retries 2 --verbose
  ```

## Contributing

Issues and pull requests are welcome:

* Bug reports should include your OS version, parser backend (`--verbose` output), and a minimal reproduction command.
* Please keep the script portable and avoid adding non-standard dependencies unless gated behind optional backends.

## License

See `LICENSE` for details.


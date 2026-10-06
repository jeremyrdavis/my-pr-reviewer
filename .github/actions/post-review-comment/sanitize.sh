#!/usr/bin/env bash
# Makes agent-written Markdown safe to post as a pull request comment.
# The agent read untrusted pull request content, so its output is untrusted too.
#
# Usage: sanitize.sh < review.md > safe.md        (MAX_BYTES overrides the size cap)
#
#   - control characters and carriage returns are removed
#   - output is capped (default 60,000 bytes; GitHub's comment limit is 65,536)
#   - "@name" mentions are broken with a zero-width space, so nobody gets notified
#   - "<!--" is escaped, so the text can't hide content or forge the comment marker
#   - Markdown images and <img> tags are defused, so nothing loads from a remote host
set -euo pipefail

max_bytes="${MAX_BYTES:-60000}"
zwsp=$'\xe2\x80\x8b'
raw="$(mktemp)"
trap 'rm -f "${raw}"' EXIT

# Read all input; remove NULs, other control characters (keeping \n and \t) and CRs.
tr -d '\000-\010\013\014\015\016-\037\177' > "${raw}"

truncated=false
if [[ "$(wc -c < "${raw}")" -gt "${max_bytes}" ]]; then
  truncated=true
  head -c "${max_bytes}" "${raw}" > "${raw}.cut"
  mv "${raw}.cut" "${raw}"
fi

# Drop a partial UTF-8 character at the cut, then apply the Markdown defenses.
# (iconv exits non-zero and warns about the cut character, which is expected here.)
{ iconv -c -f UTF-8 -t UTF-8 "${raw}" 2> /dev/null || true; } \
  | sed \
    -e 's/<!--/\&lt;!--/g' \
    -e 's/<[iI][mM][gG]/\&lt;img/g' \
    -e 's/!\[/[/g' \
    -e "s/@\([A-Za-z0-9_-]\)/@${zwsp}\1/g"

if [[ "${truncated}" == "true" ]]; then
  printf '\n\n_(The review was cut off because it was too long.)_\n'
fi

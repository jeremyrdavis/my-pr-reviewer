#!/usr/bin/env bash
# shellcheck disable=SC2016,SC2015  # literals are intentional; `cmd && ok || bad` is a reporting idiom
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
S="${ROOT}/.github/actions/post-review-comment/sanitize.sh"
need_exec "${S}"
zwsp=$'\xe2\x80\x8b'

out="$(printf 'Ping @octocat and @org/team now' | "${S}")"
assert_not_contains "${out}" '@octocat' "mentions are broken"
assert_contains "${out}" "@${zwsp}octocat" "mention keeps its text, with a zero-width space"
assert_not_contains "${out}" '@org/team' "team mentions are broken"

out="$(printf 'x <!-- sbx-pr-review --> y\n<!-- hidden' | "${S}")"
assert_not_contains "${out}" '<!--' "HTML comments are escaped, so the marker can't be forged"

out="$(printf '![t](http://evil.example/p.png) and <IMG src=x> and <img src=y>' | "${S}")"
assert_not_contains "${out}" '![' "Markdown images are defused"
assert_not_contains "${out}" '<img' "img tags are escaped (lowercase)"
assert_not_contains "${out}" '<IMG' "img tags are escaped (uppercase)"

out="$(printf 'a\000b\033[31mc\r\nd\te' | "${S}" | od -An -c | tr -d ' \n')"
assert_not_contains "${out}" '\0' "NUL bytes are removed"
assert_not_contains "${out}" '033' "escape characters are removed"
assert_not_contains "${out}" '\r' "carriage returns are removed"
assert_contains "${out}" '\t' "tabs are kept"

out="$(head -c 5000 /dev/zero | tr '\0' 'a' | MAX_BYTES=100 "${S}")"
assert_contains "${out}" 'cut off' "oversize input is truncated with a note"
(( ${#out} < 300 )) && ok "truncated output is short" || bad "truncated output is ${#out} chars"

out="$(printf 'é%.0s' $(seq 1 100) | MAX_BYTES=101 "${S}" 2> "${TMPDIR:-/tmp}/sanitize.err")"; rc=$?
assert_rc "${rc}" 0 "a cut inside a multibyte character does not make the script fail"
printf '%s' "${out}" | iconv -f UTF-8 -t UTF-8 > /dev/null 2>&1 && ok "the output is still valid UTF-8" || bad "invalid UTF-8 after truncation"
assert_contains "${out}" 'cut off' "the truncation note survives a multibyte cut"
assert_eq "$(cat "${TMPDIR:-/tmp}/sanitize.err")" "" "no stray warnings on stderr"

out="$("${S}" < /dev/null)"; rc=$?
assert_rc "${rc}" 0 "empty input succeeds"
assert_eq "${out}" "" "empty input gives empty output"

md=$'## Summary\n\n```java\nList<String> x = new ArrayList<>();\n```\n- **[minor]** `a.java:3`: fix'
assert_eq "$(printf '%s\n' "${md}" | "${S}")" "${md}" "ordinary Markdown passes through unchanged"
finish

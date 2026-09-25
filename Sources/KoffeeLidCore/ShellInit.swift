import Foundation

/// Printed by `koffeelid shell-init zsh` for `eval` in .zshrc. Held to behavioural tests in a real zsh.
public enum ShellInit {
    static let hookPlaceholder = "@KOFFEELID_HOOK@"

    /// The snippet calls the hook binary by absolute path: PATH is not ours to trust.
    public static func zsh(hookPath: String) -> String {
        zshTemplate.replacingOccurrences(of: hookPlaceholder, with: hookPath)
    }

    /// The first and last line of the block in ~/.zshrc, in the style other tools use for theirs.
    public static let zshrcHeader = "# ---------- KoffeeLid ----------"
    /// The comment that preceded the eval line before the header existed (older installs).
    public static let zshrcMarker = "# KoffeeLid: arm while a terminal command runs"
    /// The comment lines written between the header and the eval line.
    public static let zshrcDescription = [
        "# Arms KoffeeLid while a terminal command runs longer than KOFFEELID_ARM_AFTER seconds",
        "# (default 5). Guarded so a missing app is silent, not an error on every shell start.",
        "# Everything between the two \"---------- KoffeeLid ----------\" lines is removed by",
        "# Settings › Hooks › Remove (and Advanced › Reset): keep your own lines outside them.",
        "# To stop a command from auto-arming, add it to KOFFEELID_SKIP *below* the closing line",
        "# (there it extends the shipped list — vi, ssh, claude… — instead of replacing it, and",
        "# survives Remove/Reset), for example:  KOFFEELID_SKIP+=(cswap)",
    ]

    /// An uncommented line that sources KoffeeLid's snippet — ours or hand-written. Another tool's
    /// `shell-init zsh` line (SidePulse has one) is never ours.
    public static func isKoffeeLidEvalLine(_ line: Substring) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        return !t.hasPrefix("#") && t.contains("shell-init zsh") && t.lowercased().contains("koffeelid")
    }

    /// True when `text` already sources the snippet: our header, our marker, or an uncommented KoffeeLid eval line.
    public static func zshrcSourcesSnippet(_ text: String) -> Bool {
        text.split(separator: "\n", omittingEmptySubsequences: false).contains { line in
            let t = line.trimmingCharacters(in: .whitespaces)
            return t == zshrcHeader || t == zshrcMarker || isKoffeeLidEvalLine(line)
        }
    }

    /// The text ~/.zshrc should hold after adding `line`: unchanged content, one blank line, the header, the
    /// description, the line, the header again. Nil when the snippet is already sourced. A new file starts
    /// directly with the header.
    public static func zshrcAppending(_ line: String, to existing: String) -> String? {
        if zshrcSourcesSnippet(existing) { return nil }
        let separator = existing.isEmpty ? "" : (existing.hasSuffix("\n") ? "\n" : "\n\n")
        return existing + separator + ([zshrcHeader] + zshrcDescription + [line, zshrcHeader]).joined(separator: "\n") + "\n"
    }

    /// The text ~/.zshrc should hold after removing the snippet. Owned, hence removed: everything from a header
    /// line to the next header line, inclusive (the block says so in its own comment); a header with no closing
    /// header (hand-written) plus, when everything up to the next blank line is comments or KoffeeLid eval
    /// lines, that block, otherwise the header alone; the old marker comment; every uncommented KoffeeLid eval
    /// line wherever it sits. Nothing else — another tool's `shell-init zsh` line, a comment, a foreign line
    /// after an unclosed header — is touched. The blank line that separated the block goes with it. Nil when
    /// there was nothing to remove.
    public static func zshrcRemoving(from existing: String) -> String? {
        guard zshrcSourcesSnippet(existing) else { return nil }
        let lines = existing.split(separator: "\n", omittingEmptySubsequences: false)
        var kept: [Substring] = []
        var i = 0
        func trimmed(_ l: Substring) -> String { l.trimmingCharacters(in: .whitespaces) }
        func dropSeparatingBlank() {
            // The block sat between two blank lines, or at the top or the end of the file: keep one blank, or none.
            let blankBefore = kept.isEmpty || trimmed(kept.last!).isEmpty
            if blankBefore, i < lines.count, trimmed(lines[i]).isEmpty { i += 1 }
        }
        while i < lines.count {
            let line = lines[i], t = trimmed(line)
            if t == zshrcHeader {
                if let close = lines[(i + 1)...].firstIndex(where: { trimmed($0) == zshrcHeader }) {
                    i = close + 1                           // the closed block is ours, whatever it holds
                } else {
                    var j = i + 1
                    while j < lines.count, !trimmed(lines[j]).isEmpty { j += 1 }
                    let block = lines[(i + 1)..<j]
                    if block.allSatisfy({ trimmed($0).hasPrefix("#") || isKoffeeLidEvalLine($0) }) { i = j } else { i += 1 }
                }
                dropSeparatingBlank()
                continue
            }
            if t == zshrcMarker || isKoffeeLidEvalLine(line) { i += 1; dropSeparatingBlank(); continue }
            kept.append(line); i += 1
        }
        var text = kept.joined(separator: "\n")
        while text.hasSuffix("\n\n") { text.removeLast() }
        if text == "\n" { text = "" }
        return text
    }

    static let zshTemplate = #"""
# KoffeeLid: arm while a terminal command runs. Set KOFFEELID_SKIP (array of program names never
# tracked) or KOFFEELID_ARM_AFTER (seconds a command must run before it counts) before this line.
typeset -ga KOFFEELID_SKIP
(( ${#KOFFEELID_SKIP} )) || KOFFEELID_SKIP=(
  vi vim nvim emacs nano pico less more man info
  ssh mosh tmux screen top htop btop watch tig lazygit
  zsh bash sh fish su login
  claude codex grok koffeelid
)
# Declared, never reset: a `source ~/.zshrc` inside a command keeps the job it belongs to.
(( ${+_koffeelid_job} )) || typeset -g _koffeelid_job=

_koffeelid_preexec() {
  # $3 is the command line after alias expansion. Collect the head of every segment (split on
  # && || | |& ; & and the group characters), quotes stripped, basename taken: a launcher's
  # `cd '<dir>' && '<path>/vim'` must match on vim, and `(vim)` on vim, not on `(`. Leading
  # VAR=value words and the prefixes below, with their -flags (and the argument of those that take
  # one), are not the program: `sudo -u root vim` is vim. A segment of prefixes alone (`sudo -i`)
  # opens an interactive shell; a shell counts as skipped only when every word after it is a flag
  # (`bash -l`), not when it runs a script (`bash build.sh`, `sh -c …`).
  local -a words heads checked
  words=(${(z)3})
  local word bare head= prefix= skiparg= shell= skip=
  for word in $words ';'; do
    case $word in
      '&&'|'||'|'|'|'|&'|';'|'&'|'('|')'|'{'|'}')
        [[ -n $prefix && -z $head ]] && skip=1
        [[ -n $shell ]] && checked+=($head)
        head= prefix= skiparg= shell= ;;
      *)
        if [[ -n $head ]]; then
          [[ -n $shell && $word != -* ]] && shell=
          continue
        fi
        if [[ -n $skiparg ]]; then skiparg=; continue; fi
        if [[ -n $prefix && $word == -* ]]; then
          case $prefix:$word in
            sudo:-[ughpCDTUrt]|nice:-n|env:-[uCS]) skiparg=1 ;;
          esac
          continue
        fi
        bare=${word%%=*}
        [[ $word == *=* && $bare == [A-Za-z_]* && $bare != *[^A-Za-z0-9_]* ]] && continue
        bare=${${(Q)word}:t}
        case $bare in
          sudo|time|command|builtin|exec|nice|nohup|env|noglob|caffeinate) prefix=$bare; continue ;;
          zsh|bash|sh|fish) shell=1 ;;
          *) checked+=($bare) ;;
        esac
        head=$bare; heads+=($head) ;;
    esac
  done
  # One skipped head skips the whole line: the shell waits on the interactive program wherever it sits.
  [[ -n $skip ]] && return
  for head in $checked; do
    (( ${KOFFEELID_SKIP[(I)$head]} )) && return
  done
  (( ${#heads} )) || return
  local name=${heads[1]}
  local -a extra
  [[ -n ${KOFFEELID_ARM_AFTER-} ]] && extra=(--arm-after $KOFFEELID_ARM_AFTER)
  _koffeelid_job=zsh-$$
  '@KOFFEELID_HOOK@' job begin --id $_koffeelid_job --pid $$ --label $name $extra >/dev/null 2>&1
}

_koffeelid_precmd() {
  # First statement: $? is the command's status, and later precmd hooks expect to see it.
  local code=$?
  if [[ -n $_koffeelid_job ]]; then
    '@KOFFEELID_HOOK@' job end --id $_koffeelid_job >/dev/null 2>&1
    _koffeelid_job=
  fi
  return $code
}

# Loading the snippet ends the job this shell's pid holds: one an earlier image began (`exec zsh`),
# or the `source` that is reading it now.
[[ -o interactive ]] && '@KOFFEELID_HOOK@' job end --id zsh-$$ >/dev/null 2>&1
autoload -Uz add-zsh-hook
add-zsh-hook preexec _koffeelid_preexec
add-zsh-hook precmd _koffeelid_precmd
"""#
}

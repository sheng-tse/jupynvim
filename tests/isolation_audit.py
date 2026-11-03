#!/usr/bin/env python3
"""Static audit that keeps the test suite safe to run several times at once.

    python3 -I tests/isolation_audit.py [REPO]

REPO defaults to the parent of this file's directory. Every violation prints
as `RULE path:line: text`; the last line is `ALL ISOLATION AUDIT CHECKS PASSED`
(exit 0) or `N ISOLATION AUDIT VIOLATIONS` (exit 1).

  R1 fixed-tmp        no fixed system temp dir (the plain one, or the ones
                      under /private and /var) in tests, lua or core/src, on
                      any line, comments included. A temp dir name right
                      after a name, a variable or a substitution ($R, ${R},
                      $(dirname "$x") and the like) is part of that path, not
                      the fixed dir; the same holds after a placeholder such
                      as <run> in a comment or docstring, but not after a
                      redirection arrow. In Python and Lua, string pieces
                      joined with + or .. (or side by side) are read joined
  R2 blanket-kill     tests never look up or kill processes by name or
                      pattern, and never signal every process or a whole
                      process group; they stop processes by pid. That covers
                      a shell kill given 0 or a negative pid, killpg, a
                      kill(...) call (os.kill, vim.uv.kill) given 0, a group
                      id or a negative pid in any form (also written as a
                      string that is converted, int("-1")), the own pid
                      negated anywhere (-os.getpid()), and an argument list
                      that runs kill (["kill", ...], {"kill", ...}) with 0
                      or a negative pid. Comments (shell, Python, Lua) and
                      Python docstrings are prose and are not read; strings
                      and here-document bodies are read, since they can
                      become code
  R3 tmux-private     tmux only through tests/lib/tmux.sh, which picks a
                      private server and its config:
                      (a) a shell test never goes around the wrapper: no
                      escaped tmux, no tmux binary by path or through another
                      command (command, exec, env, nohup, xargs, timeout and
                      the like), no tmux inside code for another interpreter
                      (sh -c, a pipe or here-document into a shell, python -c),
                      no path lookup of the binary in a substitution, no
                      redefined or removed wrapper, and no server or config
                      option (-L, -S, -f) of its own; a Python or Lua test
                      outside tests/lib/ never names tmux as a program or a
                      command line, also not joined from string pieces. At
                      run time tests/lib/test_env.sh points TMUX_TMPDIR into
                      the run, so tmux run around the wrapper anyway finds
                      no server of the user's. One exception to the lexer
                      rule below: the five plain forms (command tmux, an
                      escaped tmux, env tmux, tmux by a bin path, tmux -L or
                      -S) are matched on every line that is not a comment,
                      inside quoted strings and here-document bodies too,
                      because such text can be written to a script and run;
                      reword a message that contains one
                      (b) a script that runs tmux sources the wrapper or
                      screen_lib.sh, and screen_lib.sh sources the wrapper. A
                      use is a command named tmux (in a substitution or a
                      function body too), eval given tmux code, or any way
                      around the wrapper found under (a); a message that names
                      tmux is not a use
  R4 run-env          every top-level test script runs in the per-run env
  R5 no-local-notes   nothing public refers to the git-ignored local notes dir
  R6 racy-tempfile    no racy temp names in Python tests
  R7 wired            every top-level test is run by tests/run_all.sh
  R8 exit-trap        no EXIT trap of a script's own; cleanup goes through
                      jnv_on_exit so the shared exit hooks keep running
  R9 run-tmp          a shell test's mktemp names its template under $TMPDIR
                      or $JNV_RUN_ROOT (or gives one of them with -p or
                      --tmpdir and a relative template), with no .. in it;
                      mktemp run through another command (timeout, nice,
                      xargs, env and the like) counts too. With -t, or with no
                      template, macOS mktemp makes the name in the per-user
                      temp dir whatever TMPDIR says, outside the run dir.
                      tests/lib/test_env.sh, which makes the run dir in the
                      caller's temp dir, and tests/run_concurrent.sh, which
                      runs outside the run env, are exempt

Shell scripts are read with a small lexer (quotes, command substitutions,
here-documents, pipelines), so apart from the plain forms of R3a, a word
inside a quoted string or a here-document body never counts as a command,
and a source line inside a string never counts as sourcing. Python is read
with tokenize and Lua with a lexer of its own, so comments and docstrings
never count. A shell file the lexer cannot read is reported (R0), and R3b and
R4 then fall back to line patterns.

This file is exempt from every rule that reads a file's content, and its
patterns are built from pieces so that it never matches its own source. It
still has to be wired into run_all.sh (R7 reads run_all.sh, not this file).
Stdlib only.
"""
import bisect
import io
import os
import re
import sys
import time
import tokenize

TMP = "/" + "tmp"
SELF_REL = "tests/" + "isolation_audit.py"
T = "tm" + "ux"

# R1: a fixed temp dir as its own path component. A path that continues a
# name, a variable or a substitution is the caller's own dir: $R, ${R} and
# $(...) end in a word character, } or ), also when the quote that closes
# them comes first ("$R"/x). An opening quote does not follow one of those,
# and neither does a redirection arrow, so "/x" and > /x are still caught.
R1_RE = re.compile(r"""(?<![\w.})])(?<![\w})]["'])(?:/""" + "private)?(?:/" + "var)?"
                   + re.escape(TMP) + r"""(?=[/"'\s)}\],;]|$)""")
# a placeholder such as <run> or <run dir> right before the match; skipped only
# inside a comment or docstring, where it names a dir instead of redirecting
PLACEHOLDER_RE = re.compile(r"<[A-Za-z][\w.-]*(?: [\w.-]+)*>$")

# R2: lookups and kills by name or pattern, kills of every process or of a
# process group, and pid lists piped into kill.
_PK, _KA, _PG, _PO, _XA = "p" + "kill", "kill" + "all", "p" + "grep", "pid" + "of", "xa" + "rgs"
R2_RES = [
    re.compile(r"\b(?:" + _PK + "|" + _KA + "|" + _PO + r")\b"),
    # a lookup by pattern; the parent-pid form lists only a known pid's children
    re.compile(r"\b" + _PG + r"\b(?![\s\"',]*-P\b)"),
    re.compile(r"\b" + _XA + r"\b[^;&|\n]*(?<![\w.-])kill(?![\w-])"),
    re.compile(r"(?<![\w.-])kill(?![\w-])[^;&|\n]*(?:\$\(|`)\s*(?:ps|" + _PG + "|" + _PO
               + r")\b"),
    # killpg signals a whole process group, whatever it is given
    re.compile(r"\bkill" + r"pg\b"),
    # the own pid negated is only ever a process group to signal
    re.compile(r"(?:^|[=(,\[{]|\breturn\b|\bthen\b)\s*-\s*[\w.:]*\b(?:getpid|getpgrp|getpgid"
               r"|os_getpid)\s*\("),
]
KILL_WORD_RE = re.compile(r"(?<![\w.$/-])kill(?=[ \t])")
# a kill(...) call: os.kill, vim.uv.kill, vim.loop.kill, a handle's kill
KILL_CALL_RE = re.compile(r"(?<![\w$])kill\s*\(")
# an argument list that runs kill: ["kill", ...] or {"kill", ...}
KILL_ARGV_RE = re.compile(r"""[\[{(]\s*(?:['"])kill(?:['"])\s*,""")
# a pid written as a string, then converted: int("-1"), tonumber("0")
STR_PID_RE = re.compile(r"""["']\s*(?:-\s*\d+|0+)\s*["']""")

# R3a, the plan's forms, on every code line of a shell test.
R3A_RES = [
    re.compile(r"\bcommand\s+" + T + r"\b"),
    re.compile(r"\\" + T + r"\b"),
    re.compile(r"\benv\s+" + T + r"\b"),
    re.compile(r"/bin/" + T + r"\b"),
    re.compile(r"\b" + T + r"\s+-[LS]\b"),
]
# R3b: the line form of a tmux use, only for a file the lexer could not read
# (the lexer finds uses otherwise, so a message that names tmux is not one).
R3B_USE_RE = re.compile(r"(^|[\s;&|(!])" + T + r"(\s|$)")

_PATHCH = r"[\w.~${}/-]"
_BEFORE = r"(?:^|[\s;&|(!{`'\"\[,])"
_AFTER = r"(?=$|[\s;&|)}`'\"\],])"
# tmux as a command word somewhere in a piece of code
TMUX_WORD_RE = re.compile(_BEFORE + "(?:" + _PATHCH + "*/)?" + T + _AFTER)
# a word or a string that is just the program
TMUX_EXACT_RE = re.compile("^(?:" + _PATHCH + "*/)?" + T + "$")
# a tmux command line: the program, its options, then a subcommand
_SUB = (r"(?:[a-z]+(?:-[a-z]+)+|ls|lsp|lsw|lsc|has|new|neww|send|display|set|setw|show|showw"
        r"|attach|source|run|wait|splitw|selectp|selectw|capturep|killp|kills|killw|resizep"
        r"|swapp|start|info|detach)")
TMUX_CMDLINE_RE = re.compile(_BEFORE + "(?:" + _PATHCH + "*/)?" + T
                             + r"(?:\s+-\w+(?:\s+[^\s-]\S*)?)*\s+" + _SUB + _AFTER)
# commands that run code given to them, or read code from stdin
INTERP_RE = re.compile(r"^(?:[a-z]*sh|perl[\d.]*|python[\d.]*|pypy[\d.]*|ruby|node(?:js)?|deno"
                       r"|bun|osascript|n?vim|vi|ex|expect|tclsh[\d.]*|wish|lua(?:jit)?[\d.]*"
                       r"|php|[gmn]?awk|julia|Rscript)$")
# commands whose tmux argument is data, not a program to run
ARG_OK_CMDS = {"echo", "printf", "test", "[", "[[", "case", "for", "select", "type", "hash",
               "which", "declare", "typeset", "local", "readonly", "export", ":", T}
# words right before a tmux argument that make it data (options skipped)
PRED_OK = {"type", "hash", "which", "declare", "typeset", "echo", "printf", "test", "[", "[[",
           "=", "==", "!="}
LOOKUPS = {"type", "which", "whence", "where", "command", "hash"}
TERM_KEY_RE = re.compile(r"^TERM\w*$")

LIB_TMUX = "lib/" + T + ".sh"
LIB_ENV = "lib/test_env.sh"
SCREEN_LIB = "screen_lib.sh"
# R5: the git-ignored local notes dir, by name.
R5_RE = re.compile(r"\." + "cl" + "aude" + r"\b")
# R6
R6_RE = re.compile(r"tempfile\.mk" + r"temp\(")

R4_EXEMPT = {"run_concurrent.sh"}
R7_EXEMPT = {"run_all.sh", "screen_lib.sh", "png_fixture.lua", "run_concurrent.sh",
             "isolation_spec.py"}
R8_EXEMPT = {"tests/lib/test_env.sh"}
R9_EXEMPT = {"tests/lib/test_env.sh", "tests/run_concurrent.sh"}
R3_EXEMPT = {"tests/" + LIB_TMUX}
PRUNE = {".git", "__pycache__", "node_modules", "target"}

HINTS = {
    "R0": "the file could not be read as code, so R3, R4 and R8 could not check it",
    "R1": "use $TMPDIR (mktemp with a template under it), tempfile.mkstemp or vim.fn.tempname(),"
          " never a fixed temp dir",
    "R2": "stop only processes the run started, by pid (tests/lib/run_procs.py)",
    "R3": "shell tests source tests/lib/" + T + ".sh (or screen_lib.sh) and call plain `" + T
          + "`, and the lib picks a private server and its config; Python and Lua tests do"
          " not run " + T + " (there is no lib helper for them): drive it from a shell test",
    "R4": "source tests/lib/test_env.sh, tests/lib/" + T + ".sh or tests/screen_lib.sh",
    "R5": "keep tests, code and public docs free of the git-ignored local notes dir",
    "R6": "use tempfile.mkstemp or tempfile.mkdtemp",
    "R7": "run the test from tests/run_all.sh",
    "R8": "register cleanup with jnv_on_exit instead of an EXIT trap",
    "R9": "mktemp with a template under the run's temp dir: mktemp -d \"$TMPDIR/name.XXXXXX\"",
    "SE": "a rule misread one of its own probes (SELF_TEST_FILES): fix the rule, not the probe",
}


# ── shell lexer ─────────────────────────────────────────

class Word:
    __slots__ = ("raw", "value", "line")

    def __init__(self, raw, value, line):
        self.raw, self.value, self.line = raw, value, line


class Cmd:
    """One simple command. words has quotes removed in value (command and
    parameter substitutions stay as written) and leaves out redirection
    targets. subst: inside a command or process substitution; sub: that, or
    inside a ( ) subshell. pipe and pos place it in its pipeline."""
    __slots__ = ("words", "subst", "sub", "pipe", "pos", "heredocs", "herestrings", "funcdef")

    def __init__(self, subst, pipe, pos):
        self.words, self.subst, self.sub, self.pipe, self.pos = [], subst, subst, pipe, pos
        self.heredocs, self.herestrings, self.funcdef = [], [], False


REDIR_RE = re.compile(r"&>>|&>|>>|>&|>\||<<<|<<-|<<|<&|<>|>|<")
CTRL_RE = re.compile(r";;&|;;|;&|&&|\|\||\|&|;|&|\||\(|\)")
FD_RE = re.compile(r"^(?:\d+|\{\w+\})$")


class _Frame:
    """The lexer state of one nesting level (the file, or a substitution)."""

    def __init__(self, lx, subst):
        self.lx, self.subst, self.depth = lx, subst, 0
        self.word, self.redirect, self.pending = None, None, []
        lx.npipe += 1
        self.cur = Cmd(subst, lx.npipe, 0)

    def start_word(self, i):
        if self.word is None:
            self.word = ([], [], i)

    def add(self, raw, value):
        self.word[0].append(raw)
        self.word[1].append(value)

    def end_word(self):
        w = self.word
        if w is None:
            return
        self.word = None
        word = Word("".join(w[0]), "".join(w[1]), self.lx.line_of(w[2]))
        r, self.redirect = self.redirect, None
        if r is None:
            self.cur.words.append(word)
        elif r == "herestring":
            self.cur.herestrings.append(word)
        elif r in ("<<", "<<-"):
            self.pending.append((self.cur, word.value, r == "<<-"))

    def end_cmd(self, piped):
        self.end_word()
        self.redirect = None
        c = self.cur
        c.sub = self.subst or self.depth > 0
        if c.words:
            self.lx.cmds.append(c)
        if piped:
            self.cur = Cmd(self.subst, c.pipe, c.pos + 1)
        else:
            self.lx.npipe += 1
            self.cur = Cmd(self.subst, self.lx.npipe, 0)

    def read_heredocs(self, i, end):
        """Consume the bodies of the here-documents opened on the line that
        just ended; i is the start of the next line."""
        t = self.lx.text
        for cmd, delim, strip in self.pending:
            body = []
            while i < end:
                j = t.find("\n", i, end)
                j = end if j < 0 else j
                ln = t[i:j]
                if (ln.lstrip("\t") if strip else ln) == delim:
                    i = j + 1
                    break
                body.append((self.lx.line_of(i), ln))
                i = j + 1
            cmd.heredocs.append(body)
        self.pending = []
        return i


class ShellLexer:
    """Enough of POSIX sh and bash to see each simple command's words, nested
    substitutions, pipelines and here-document bodies. It never runs anything."""

    def __init__(self, text):
        self.text = text
        self.cmds = []
        self.comments = []  # (start, end) offsets of each comment
        self.npipe = 0
        self.starts = [0] + [m.end() for m in re.finditer("\n", text)]

    def line_of(self, i):
        return bisect.bisect_right(self.starts, i)

    def run(self):
        self._lex(0, len(self.text), False)
        return self.cmds

    # scanners that only find where something ends
    def _skip_sq(self, k, end):
        j = self.text.find("'", k + 1, end)
        return end if j < 0 else j + 1

    def _skip_dq(self, k, end, lex=False):
        """k at a double quote; returns (index after the closing quote, value)."""
        t, val = self.text, []
        k += 1
        while k < end:
            ch = t[k]
            if ch == "\\" and k + 1 < end:
                nx = t[k + 1]
                if nx != "\n":
                    val.append(nx if nx in '$`"\\' else ch + nx)
                k += 2
                continue
            if ch == '"':
                return k + 1, "".join(val)
            if ch == "$" and k + 1 < end and t[k + 1] in "({":
                j = self._dollar(k, end, lex)
                val.append(t[k:j])
                k = j
                continue
            if ch == "`":
                j = self._backtick(k, end, lex)
                val.append(t[k:j])
                k = j
                continue
            val.append(ch)
            k += 1
        return end, "".join(val)

    def _skip_ansi(self, k, end):
        """k at the quote of $'...'; returns the index after the closing quote."""
        t = self.text
        k += 1
        while k < end:
            if t[k] == "\\":
                k += 2
                continue
            if t[k] == "'":
                return k + 1
            k += 1
        return end

    def _match_paren(self, i, end):
        """i at an opening paren; the index of its closing paren."""
        t, depth, k = self.text, 0, i
        while k < end:
            ch = t[k]
            if ch == "\\":
                k += 2
                continue
            if ch == "'":
                k = self._skip_sq(k, end)
                continue
            if ch == '"':
                k = self._skip_dq(k, end)[0]
                continue
            if ch == "`":
                k = self._backtick(k, end, False)
                continue
            if ch == "#" and t[k - 1] in " \t\n;(|&":
                j = t.find("\n", k, end)
                j = end if j < 0 else j
                self.comments.append((k, j))
                k = j
                continue
            if ch == "(":
                depth += 1
            elif ch == ")":
                depth -= 1
                if depth == 0:
                    return k
            k += 1
        return end - 1

    def _match_brace(self, i, end):
        t, depth, k = self.text, 0, i
        while k < end:
            ch = t[k]
            if ch == "\\":
                k += 2
                continue
            if ch == "'":
                k = self._skip_sq(k, end)
                continue
            if ch == '"':
                k = self._skip_dq(k, end)[0]
                continue
            if ch == "{":
                depth += 1
            elif ch == "}":
                depth -= 1
                if depth == 0:
                    return k
            k += 1
        return end - 1

    def _dollar(self, i, end, lex):
        """i at a $ before ( or {; the index after the whole expansion. A
        command substitution's commands are lexed when lex is set."""
        t = self.text
        if t[i + 1] == "{":
            return self._match_brace(i + 1, end) + 1
        j = self._match_paren(i + 1, end)
        if lex and not t.startswith("((", i + 1):
            self._lex(i + 2, j, True)
        return j + 1

    def _backtick(self, i, end, lex):
        t, k = self.text, i + 1
        while k < end:
            if t[k] == "\\":
                k += 2
                continue
            if t[k] == "`":
                break
            k += 1
        if lex:
            self._lex(i + 1, min(k, end), True)
        return min(k + 1, end)

    def _lex(self, i, end, subst):
        t = self.text
        st = _Frame(self, subst)
        while i < end:
            c = t[i]
            nx = t[i + 1] if i + 1 < end else ""
            if st.word is None:
                if c in " \t\r":
                    i += 1
                    continue
                if c == "\\" and nx == "\n":
                    i += 2
                    continue
                if c == "\n":
                    st.end_cmd(False)
                    i = st.read_heredocs(i + 1, end)
                    continue
                if c == "#":
                    j = t.find("\n", i, end)
                    j = end if j < 0 else j
                    self.comments.append((i, j))
                    i = j
                    continue
            elif c in " \t\r\n":
                st.end_word()
                continue
            if c in "<>" and nx == "(":  # process substitution, part of a word
                st.start_word(i)
                j = self._match_paren(i + 1, end)
                self._lex(i + 2, j, True)
                st.add(t[i:j + 1], t[i:j + 1])
                i = j + 1
                continue
            if c in "<>" or (c == "&" and nx == ">"):
                if st.word is not None and FD_RE.match("".join(st.word[0])):
                    st.word = None  # the fd number of this redirection
                else:
                    st.end_word()
                op = REDIR_RE.match(t, i).group(0)
                i += len(op)
                st.redirect = op if op in ("<<", "<<-") else (
                    "herestring" if op == "<<<" else "target")
                continue
            if c in ";&|()":
                if c == "(" and st.word is not None and "".join(st.word[0]).endswith("="):
                    j = self._match_paren(i, end)  # an array literal
                    st.add(t[i:j + 1], t[i:j + 1])
                    i = j + 1
                    continue
                st.end_word()
                op = CTRL_RE.match(t, i).group(0)
                if op == "(":
                    k = i + 1
                    while k < end and t[k] in " \t":
                        k += 1
                    if len(st.cur.words) == 1 and k < end and t[k] == ")":
                        st.cur.funcdef = True  # name () ...
                        st.end_cmd(False)
                        i = k + 1
                        continue
                    st.end_cmd(False)
                    st.depth += 1
                elif op == ")":
                    st.end_cmd(False)
                    st.depth = max(0, st.depth - 1)
                else:
                    st.end_cmd(op in ("|", "|&"))
                i += len(op)
                continue
            st.start_word(i)
            if c == "'":
                j = self._skip_sq(i, end)
                st.add(t[i:j], t[i + 1:j - 1])
                i = j
            elif c == "$" and nx == "'":
                j = self._skip_ansi(i + 1, end)
                st.add(t[i:j], t[i + 2:j - 1])
                i = j
            elif c == '"':
                j, val = self._skip_dq(i, end, lex=True)
                st.add(t[i:j], val)
                i = j
            elif c == "\\":
                if nx != "\n":
                    st.add(t[i:i + 2], nx)
                i += 2
            elif c == "$" and nx in "({":
                j = self._dollar(i, end, True)
                st.add(t[i:j], t[i:j])
                i = j
            elif c == "`":
                j = self._backtick(i, end, True)
                st.add(t[i:j], t[i:j])
                i = j
            else:
                st.add(c, c)
                i += 1
        st.end_cmd(False)


SKIP_WORDS = {"!", "{", "}", "if", "then", "else", "elif", "fi", "do", "done", "while",
              "until", "time", "esac", "coproc"}
ASSIGN_RE = re.compile(r"^[A-Za-z_]\w*(?:\[[^\]]*\])?\+?=")


def effective(words):
    """The words from the command name on: reserved words that open a
    command and leading variable assignments are dropped."""
    k = 0
    while k < len(words):
        r = words[k].raw
        if r in SKIP_WORDS or (r == "-p" and k and words[k - 1].raw == "time") \
                or ASSIGN_RE.match(r):
            k += 1
        else:
            break
    return words[k:]


def base(v):
    return v.rsplit("/", 1)[-1]


def tmux_line(w):
    """The line of the first tmux command word inside a word (a quoted
    string can span lines), or None."""
    m = TMUX_WORD_RE.search(w.value)
    return None if m is None else w.line + w.value.count("\n", 0, m.start())


def interp_index(ws):
    """Index of the first word that names a program which runs code, or None.
    A command name that is an expansion counts too."""
    for k, w in enumerate(ws):
        if k == 0 and w.value.startswith("$"):
            return 0
        if INTERP_RE.match(base(w.value)):
            return k
    return None


def tmux_global_opts(args):
    """The server and config options given before the subcommand."""
    bad, k = [], 0
    while k < len(args):
        a = args[k]
        if a == "--" or not a.startswith("-") or a == "-":
            break
        cl = a[1:]
        for j, ch in enumerate(cl):
            if ch in "LSf":
                bad.append("-" + ch)
            if ch in "cfLST":  # takes an argument
                if j == len(cl) - 1:
                    k += 1
                break
        k += 1
    return bad


def shell_tmux_issues(cmd):
    """(line, why) for each way this command goes around the wrapper."""
    ws = effective(cmd.words)
    if not ws:
        return []
    out = []
    name, vals = ws[0], [w.value for w in ws]
    nv = vals[0]
    if nv != T and TMUX_EXACT_RE.match(nv):
        out.append((name.line, "runs the " + T + " binary by its path"))
    if nv == T:
        if cmd.funcdef:
            out.append((name.line, "redefines the " + T + " wrapper"))
        else:
            bad = tmux_global_opts(vals[1:])
            if bad:
                out.append((name.line, "gives its own " + " ".join(bad)
                            + "; only the lib picks the server and config"))
    if nv == "function" and len(vals) > 1 and vals[1] in (T, T + "()"):
        out.append((name.line, "redefines the " + T + " wrapper"))
    if nv == "unset" and "-f" in vals[1:] and T in vals[1:]:
        out.append((name.line, "removes the " + T + " wrapper"))
    if nv == "alias" and any(v.startswith(T + "=") for v in vals[1:]):
        out.append((name.line, "aliases " + T))
    if nv not in ARG_OK_CMDS and nv not in ("function", "unset"):
        for k in range(1, len(ws)):
            if not TMUX_EXACT_RE.match(vals[k]):
                continue
            j, opts = k - 1, []
            while j > 0 and vals[j].startswith("-") and vals[j] != "-":
                opts.append(vals[j])
                j -= 1
            pred = vals[j]
            if pred in PRED_OK or (pred == "command" and ("-v" in opts or "-V" in opts)):
                continue
            out.append((ws[k].line, T + " run through " + (base(nv) or nv)
                        + ", which skips the wrapper"))
    if cmd.subst and nv in LOOKUPS and any(TMUX_EXACT_RE.match(v) for v in vals[1:]):
        opts = [v for v in vals[1:] if v.startswith("-")]
        if not (nv == "type" and opts == ["-t"]):
            out.append((name.line, "looks up the " + T + " binary's path in a substitution"))
    if nv not in (T, "echo", "printf"):
        k = interp_index(ws)
        if k is not None:
            who = base(vals[k]) or vals[k]
            for w in ws[k + 1:]:
                line = tmux_line(w)
                if line is not None:
                    out.append((line, T + " inside code for " + who + ", which has no wrapper"))
            for w in cmd.herestrings:
                line = tmux_line(w)
                if line is not None:
                    out.append((line, T + " in a here-string for " + who
                                + ", which has no wrapper"))
            for body in cmd.heredocs:
                for line, text in body:
                    if TMUX_WORD_RE.search(text):
                        out.append((line, T + " in a here-document for " + who
                                    + ", which has no wrapper"))
    return out


def pipe_tmux_issues(cmds):
    """tmux text piped into a program that runs it."""
    out, by_pipe = [], {}
    for c in cmds:
        by_pipe.setdefault(c.pipe, []).append(c)
    for group in by_pipe.values():
        if len(group) < 2:
            continue
        group.sort(key=lambda c: c.pos)
        for idx, c in enumerate(group):
            ws = effective(c.words)
            if c.pos == 0 or not ws or ws[0].value == T:
                continue
            k = interp_index(ws)
            if k is None:
                continue
            for before in group[:idx]:
                for w in effective(before.words)[1:] + before.herestrings:
                    line = tmux_line(w)
                    if line is not None:
                        out.append((line, T + " piped into " + base(ws[k].value)
                                    + ", which has no wrapper"))
    return out


def sources(cmds, names):
    """True when a top-level command sources a file whose path ends in one of
    names (a `source` inside a string, a here-document, a substitution or a
    subshell does not count)."""
    pats = [re.compile(r"(?:^|/)" + re.escape(n) + "$") for n in names]
    for c in cmds:
        if c.sub:
            continue
        ws = effective(c.words)
        if len(ws) >= 2 and ws[0].value in ("source", ".") \
                and any(p.search(ws[1].value) for p in pats):
            return True
    return False


SOURCE_LINE_RE = re.compile(r"^\s*(?:(?:if|elif|then|else|do|!|\{)\s+)*(?:source|\.)\s+(.*)$")
# where the source command's argument ends: a list operator, a separator or a
# comment (a path such as "$(dirname "$0")/x" holds spaces, so not at a space)
SOURCE_ARG_END_RE = re.compile(r"\s+(?:\|\||&&|#)|[;&|]")


def sources_by_line(lines, names):
    """The line form of sources(), used only for a file the lexer could not
    read: a line that starts with source or . and whose argument ends in the
    file's name."""
    end = re.compile("(?:" + "|".join(r"(?<![\w.-])" + re.escape(n) for n in names)
                     + r""")["']?\s*$""")
    for ln in lines:
        m = SOURCE_LINE_RE.match(ln)
        if m and end.search(SOURCE_ARG_END_RE.split(m.group(1), maxsplit=1)[0]):
            return True
    return False


def tmux_use_lines(cmds):
    """Lines of the commands that run tmux: a command named tmux (also in a
    substitution, a function body or after if, ! or time), or eval given
    tmux code. A word in a message or a here-document body is not a use."""
    out = []
    for c in cmds:
        ws = effective(c.words)
        if not ws:
            continue
        if ws[0].value == T and not c.funcdef:
            out.append(ws[0].line)
        elif ws[0].value == "eval":
            out += [ln for ln in (tmux_line(w) for w in ws[1:]) if ln is not None]
    return out


EXIT_SPEC_RE = re.compile(r"(?i)^(?:(?:sig)?exit|0)$")


def sets_exit_trap(cmd):
    """True when this command sets or resets the EXIT trap."""
    vals = [w.value for w in effective(cmd.words)]
    while vals and vals[0] in ("builtin", "command"):
        vals = vals[1:]
    if not vals or vals[0] != "trap":
        return False
    args = vals[1:]
    while args and args[0].startswith("-") and args[0] != "-":
        a = args.pop(0)
        if a in ("-p", "-l"):
            return False  # lists traps, sets none
        if a == "--":
            break
    if not args:
        return False
    specs = args if len(args) == 1 else args[1:]
    return any(EXIT_SPEC_RE.match(s) for s in specs)


# R9: the run's temp dirs, as a template or a -p dir may start with them
# (quotes are already removed from a word's value)
R9_DIRS = ("TMPDIR", "JNV_RUN_ROOT")


def under_run_tmp(v, exact_ok=False):
    """True when the word value v is a path under $TMPDIR or $JNV_RUN_ROOT
    (or one of them, with exact_ok), with no .. that climbs out of it."""
    if ".." in v.split("/"):
        return False
    for d in R9_DIRS:
        for form in ("$" + d, "${" + d + "}"):
            if v.startswith(form + "/") or (exact_ok and v == form):
                return True
    return False


def mktemp_issue(cmd):
    """(line, why) when this command runs mktemp in a way that can make the
    name outside the run's temp dir, else None. As R3 reads tmux, mktemp is
    run by any command that is given it as a word (timeout 5 mktemp, nice
    mktemp, xargs mktemp, env mktemp), unless that command only takes it as
    data (echo, printf, test and the like)."""
    ws = effective(cmd.words)
    names = [base(w.value) for w in ws]
    if not names or "mktemp" not in names:
        return None
    k = names.index("mktemp")
    if k > 0:
        if names[0] in ARG_OK_CMDS:
            return None
        j, opts = k - 1, []
        while j > 0 and names[j].startswith("-") and names[j] != "-":
            opts.append(names[j])
            j -= 1
        if names[j] in PRED_OK or (names[j] == "command" and ("-v" in opts or "-V" in opts)):
            return None
    line, args = ws[k].line, [w.value for w in ws[k + 1:]]
    templates, tmpdir, i = [], None, 0
    while i < len(args):
        a = args[i]
        if a == "--":
            templates += args[i + 1:]
            break
        if a.startswith("--"):
            name, eq, val = a[2:].partition("=")
            if name == "tmpdir":
                tmpdir = val if eq else ""
            elif name == "suffix" and not eq:
                i += 1
            i += 1
            continue
        if a.startswith("-") and a != "-":
            flags = a[1:]
            for j, ch in enumerate(flags):
                if ch == "t":
                    return (line, "uses -t, which on macOS makes the name in the per-user temp"
                            " dir, not under $TMPDIR")
                if ch == "p":
                    tmpdir = flags[j + 1:]
                    if not tmpdir:
                        i += 1
                        tmpdir = args[i] if i < len(args) else ""
                    break
            i += 1
            continue
        templates.append(a)
        i += 1
    if not templates:
        return (line, "has no template, so on macOS it makes the name in the per-user temp"
                " dir, not under $TMPDIR")
    for t in templates:
        if ".." in t.split("/"):
            return (line, "climbs out of the run's temp dir with .. (" + t + ")")
        relative = not t.startswith(("/", "$", "~", "`"))
        if not (under_run_tmp(t)
                or (relative and tmpdir is not None and under_run_tmp(tmpdir, exact_ok=True))):
            return (line, "makes its name outside $TMPDIR and $JNV_RUN_ROOT (" + t + ")")
    return None


def kill_targets_all(line):
    """True when a shell kill command on this line targets every process,
    this script's own process group or any other whole process group."""
    for m in KILL_WORD_RE.finditer(line):
        rest = re.split(r"[;&|)`\n]", line[m.end():], maxsplit=1)[0]
        toks = [x.strip("\"'") for x in rest.split()]
        i = 0
        if toks and toks[0].startswith("-") and toks[0] != "--":
            if toks[0] in ("-l", "-L"):
                continue
            i = 2 if toks[0] in ("-s", "-n") else 1
        if i < len(toks) and toks[i] == "--":
            i += 1
        if any(x == "0" or (x.startswith("-") and len(x) > 1) for x in toks[i:]):
            return True
    return False


_OPEN, _CLOSE = "([{", ")]}"


def _call_args(line, pos):
    """The arguments of the call whose ( ends right before pos, split at the
    top-level commas, as far as the line goes (strings kept whole)."""
    args, cur, depth, i, q = [], "", 0, pos, None
    while i < len(line):
        ch = line[i]
        if q:
            cur += ch
            if ch == "\\" and i + 1 < len(line):
                cur += line[i + 1]
                i += 1
            elif ch == q:
                q = None
        elif ch in "'\"":
            q = ch
            cur += ch
        elif ch in _OPEN:
            depth += 1
            cur += ch
        elif ch in _CLOSE:
            if depth == 0:
                break
            depth -= 1
            cur += ch
        elif ch == "," and depth == 0:
            args.append(cur)
            cur = ""
        else:
            cur += ch
        i += 1
    args.append(cur)
    return [a.strip() for a in args]


def _minus_outside_subscript(text):
    """A minus sign in text that is not inside [...] (an index such as
    pids[-1]) or a string."""
    stack, q, i = [], None, 0
    while i < len(text):
        ch = text[i]
        if q:
            if ch == "\\":
                i += 1
            elif ch == q:
                q = None
        elif ch in "'\"":
            q = ch
        elif ch in _OPEN:
            stack.append(ch)
        elif ch in _CLOSE:
            if stack:
                stack.pop()
        elif ch == "-" and (not stack or stack[-1] != "["):
            return True
        i += 1
    return False


def kill_call_targets_group(line):
    """True when a kill(...) call on this line is given a pid that is 0, a
    process group id, or negative in any form (-pid, 0 - pid, pid * -1,
    int(-pid)): each signals a whole process group, or every process."""
    for m in KILL_CALL_RE.finditer(line):
        args = _call_args(line, m.end())
        pid = args[0] if args else ""
        if not pid:
            continue
        if pid == "0" or "getpgrp" in pid or "getpgid" in pid or _minus_outside_subscript(pid) \
                or STR_PID_RE.search(pid):
            return True
    return False


def _arg_text(a):
    """An argument with a string prefix and its opening quote taken off."""
    a = a.strip()
    a = re.sub(r"^[rRbBfFuU]{1,2}(?=['\"])", "", a)
    return a[1:] if a[:1] in ("'", '"') else a


def argv_kill_targets_all(line):
    """True when an argument list that runs kill (["kill", ...] in Python,
    {"kill", ...} in Lua) names 0 or a negative pid, as kill_targets_all
    reads a shell kill command."""
    for m in KILL_ARGV_RE.finditer(line):
        toks = [_arg_text(a) for a in _call_args(line, m.end())]
        toks = [t for t in toks if t]
        i = 0
        if toks and toks[0].startswith("-") and not toks[0].startswith("--"):
            if toks[0].startswith(("-l", "-L")):
                continue
            i = 2 if toks[0].rstrip("'\"") in ("-s", "-n") else 1
        if i < len(toks) and toks[i].rstrip("'\"") == "--":
            i += 1
        for t in toks[i:]:
            if t.rstrip("'\"") == "0" or (t.startswith("-") and len(t.rstrip("'\"")) > 1):
                return True
    return False


# ── Python and Lua string literals ──────────────────────

def literal_issue(content, prev, prev2):
    """Why a string literal names tmux as something to run, or None. A bare
    program name is fine as the right side of a comparison or as the value of
    a TERM variable (prev is the token before the literal, prev2 the name or
    key before an `=` or `:`)."""
    if TMUX_CMDLINE_RE.search(content):
        return "a " + T + " command line"
    if TMUX_EXACT_RE.match(content.strip()):
        if prev in ("==", "!=", "~=", "is"):
            return None
        if prev in ("=", ":") and prev2 is not None and TERM_KEY_RE.match(prev2):
            return None
        return "the " + T + " program"
    return None


_STR_RE = re.compile(r"^[A-Za-z]*('''|\"\"\"|'|\")(.*)\1$", re.S)


def _str_content(s):
    m = _STR_RE.match(s)
    return m.group(2) if m else s


def _tok_types(*names):
    return {getattr(tokenize, n) for n in names if hasattr(tokenize, n)}


_FS_START = _tok_types("FSTRING_START", "TSTRING_START")
_FS_MID = _tok_types("FSTRING_MIDDLE", "TSTRING_MIDDLE")
_FS_END = _tok_types("FSTRING_END", "TSTRING_END")
_PY_SKIP = {tokenize.COMMENT, tokenize.NL, tokenize.ENCODING}
_PY_STMT = {tokenize.NEWLINE, tokenize.INDENT, tokenize.DEDENT}


def _is_docstring(toks, s, e):
    """toks[s..e] (comments and blank lines left out) is a string that is a
    statement of its own, such as a docstring: it never runs."""
    prev = toks[s - 1] if s else None
    nxt = toks[e + 1] if e + 1 < len(toks) else None
    return (prev is None or prev.type in _PY_STMT) and \
        (nxt is None or nxt.type in (tokenize.NEWLINE, tokenize.ENDMARKER))


def py_prose_spans(text):
    """(start, end) offsets of the comments and docstrings, or None when the
    file does not tokenize."""
    try:
        all_toks = list(tokenize.generate_tokens(io.StringIO(text).readline))
    except Exception:
        return None
    starts = [0] + [m.end() for m in re.finditer("\n", text)]

    def off(rc):
        return starts[rc[0] - 1] + rc[1] if rc[0] - 1 < len(starts) else len(text)
    toks = [x for x in all_toks if x.type not in _PY_SKIP]
    spans = [(off(x.start), off(x.end)) for x in all_toks if x.type == tokenize.COMMENT]
    spans += [(off(x.start), off(x.end)) for idx, x in enumerate(toks)
              if x.type == tokenize.STRING and _is_docstring(toks, idx, idx)]
    return spans


def py_tmux_issues(text):
    """(line, why) per literal, or None when the file does not tokenize."""
    try:
        toks = [x for x in tokenize.generate_tokens(io.StringIO(text).readline)
                if x.type not in _PY_SKIP]
    except Exception:
        return None
    lits, stack = [], []
    for idx, x in enumerate(toks):
        if x.type in _FS_START:
            stack.append((idx, []))
        elif x.type in _FS_MID and stack:
            stack[-1][1].append(x.string)
        elif x.type in _FS_END and stack:
            s, parts = stack.pop()
            lits.append((s, idx, "".join(parts)))
        elif x.type == tokenize.STRING:
            lits.append((idx, idx, _str_content(x.string)))
    out = []
    for s, e, content in lits:
        prev = toks[s - 1] if s else None
        if _is_docstring(toks, s, e):
            continue  # a docstring, never run
        p2 = None
        if prev is not None and prev.string in ("=", ":") and s >= 2:
            k = s - 2
            if toks[k].string == "]" and k >= 1:
                k -= 1
            p2 = _str_content(toks[k].string) if toks[k].type == tokenize.STRING \
                else toks[k].string
        why = literal_issue(content, prev.string if prev is not None else None, p2)
        if why:
            out.append((toks[s].start[0], why))
    for line, content, s in py_joined(toks):
        prev = toks[s - 1].string if s else None
        why = literal_issue(content, prev, None)
        if why:
            out.append((line, why + ", joined from string pieces"))
    return out


def py_joined(toks):
    """(line, text, index) for each run of two or more plain string literals
    joined with + or written side by side ("tm" + "ux", "/" "tmp"): what the
    run makes is read as one literal."""
    out, i = [], 0
    while i < len(toks):
        if toks[i].type != tokenize.STRING:
            i += 1
            continue
        parts, j = [_str_content(toks[i].string)], i + 1
        while j < len(toks):
            if toks[j].type == tokenize.STRING:
                parts.append(_str_content(toks[j].string))
                j += 1
            elif toks[j].string == "+" and j + 1 < len(toks) and toks[j + 1].type == tokenize.STRING:
                parts.append(_str_content(toks[j + 1].string))
                j += 2
            else:
                break
        if len(parts) > 1:
            out.append((toks[i].start[0], "".join(parts), i))
        i = j
    return out


def py_joined_text(text):
    """py_joined for the source text, or None when it does not tokenize."""
    try:
        toks = [x for x in tokenize.generate_tokens(io.StringIO(text).readline)
                if x.type not in _PY_SKIP]
    except Exception:
        return None
    return [(line, content) for line, content, _ in py_joined(toks)]


_LUA_TOK_RE = re.compile(
    r"--\[(=*)\[.*?\]\1\]|--[^\n]*"
    r"|\[(=*)\[(.*?)\]\2\]"
    r"|\"((?:\\.|[^\"\\\n])*)\"|'((?:\\.|[^'\\\n])*)'"
    r"|([A-Za-z_]\w*)"
    r"|(==|~=|<=|>=|\.\.\.?|::|\S)", re.S)


def lua_prose_spans(text):
    """(start, end) offsets of the comments."""
    return [(m.start(), m.end()) for m in _LUA_TOK_RE.finditer(text)
            if m.group(0).startswith("--")]


RS_COMMENT_LINE_RE = re.compile(r"(?m)^[ \t]*//.*$")


def _lua_toks(text):
    """(kind, value, offset) per Lua token, comments left out: s a string, n
    a name, o anything else."""
    toks = []
    for m in _LUA_TOK_RE.finditer(text):
        g = m.group(0)
        if g.startswith("--"):
            continue
        for grp, kind in ((3, "s"), (4, "s"), (5, "s"), (6, "n")):
            if m.group(grp) is not None:
                toks.append((kind, m.group(grp), m.start()))
                break
        else:
            toks.append(("o", g, m.start()))
    return toks


def lua_joined(toks, starts):
    """(line, text, index) for each run of two or more string literals joined
    with .. ("tm" .. "ux"), read as one literal."""
    out, i = [], 0
    while i < len(toks):
        if toks[i][0] != "s":
            i += 1
            continue
        parts, j = [toks[i][1]], i + 1
        while j + 1 < len(toks) and toks[j] == ("o", "..", toks[j][2]) and toks[j + 1][0] == "s":
            parts.append(toks[j + 1][1])
            j += 2
        if len(parts) > 1:
            out.append((bisect.bisect_right(starts, toks[i][2]), "".join(parts), i))
        i = j
    return out


def lua_joined_text(text):
    starts = [0] + [m.end() for m in re.finditer("\n", text)]
    return [(line, content) for line, content, _ in lua_joined(_lua_toks(text), starts)]


def lua_tmux_issues(text):
    starts = [0] + [m.end() for m in re.finditer("\n", text)]
    toks = _lua_toks(text)
    out = []
    for i, (kind, val, pos) in enumerate(toks):
        if kind != "s":
            continue
        prev = toks[i - 1][1] if i and toks[i - 1][0] == "o" else None
        p2 = None
        if prev == "=" and i >= 2:
            j = i - 2
            if toks[j][1] == "]" and j >= 1:
                j -= 1
            if toks[j][0] in ("n", "s"):
                p2 = toks[j][1]
        why = literal_issue(val, prev, p2)
        if why:
            out.append((bisect.bisect_right(starts, pos), why))
    for line, content, i in lua_joined(toks, starts):
        prev = toks[i - 1][1] if i and toks[i - 1][0] == "o" else None
        why = literal_issue(content, prev, None)
        if why:
            out.append((line, why + ", joined from string pieces"))
    return out


_FALLBACK_RE = re.compile(r"""(["'])(?:""" + _PATHCH + "*/)?" + T + r"\1")


def fallback_tmux_issues(lines):
    return [(i, "the " + T + " program or a " + T + " command line")
            for i, ln in enumerate(lines, 1)
            if _FALLBACK_RE.search(ln) or TMUX_CMDLINE_RE.search(ln)]


# ── the audit ───────────────────────────────────────────

class Audit:
    def __init__(self, repo):
        self.repo = repo
        self.found = []  # (rule, rel, line, text)
        self._lines = {}
        self._cmds = {}
        self._comments = {}
        self._masked = {}

    def add(self, rule, rel, line, text):
        text = text.strip()
        if len(text) > 160:
            text = text[:157] + "..."
        self.found.append((rule, rel, line, text))

    def lines(self, rel):
        """The file's lines, or None for a binary or unreadable file."""
        if rel not in self._lines:
            try:
                with open(os.path.join(self.repo, rel), "rb") as f:
                    data = f.read()
            except OSError:
                data = None
            if data is None or b"\0" in data[:8192]:
                self._lines[rel] = None
            else:
                text = data.decode("utf-8", errors="replace")
                self._lines[rel] = [ln[:-1] if ln.endswith("\r") else ln
                                    for ln in text.split("\n")]
        return self._lines[rel]

    def line_text(self, rel, line):
        lines = self.lines(rel) or []
        return lines[line - 1] if 0 < line <= len(lines) else ""

    def cmds(self, rel):
        """The shell commands of a file, or None when it cannot be lexed."""
        if rel not in self._cmds:
            try:
                lx = ShellLexer("\n".join(self.lines(rel) or []))
                self._cmds[rel] = lx.run()
                self._comments[rel] = lx.comments
            except Exception as e:  # never let one odd file stop the audit
                self._cmds[rel] = None
                self.add("R0-parse", rel, 1, "could not be read as shell: " + repr(e))
        return self._cmds[rel]

    def prose_masked(self, rel):
        """The file's lines with its comments, and Python docstrings, blanked
        out character for character, or None when that is not known (another
        file type, or a file that does not parse). Here-document bodies and
        strings stay: text there can become a script."""
        if rel not in self._masked:
            lines, spans = self.lines(rel), None
            text = "\n".join(lines or [])
            if lines is None:
                pass
            elif rel.endswith(".sh"):
                if self.cmds(rel) is not None:
                    spans = self._comments[rel]
            elif rel.endswith(".py"):
                spans = py_prose_spans(text)
            elif rel.endswith(".lua"):
                spans = lua_prose_spans(text)
            elif rel.endswith(".rs"):
                spans = [(m.start(), m.end()) for m in RS_COMMENT_LINE_RE.finditer(text)]
            if spans is None:
                self._masked[rel] = None
            else:
                chars = list(text)
                for s, e in spans:
                    for k in range(s, min(e, len(chars))):
                        if chars[k] != "\n":
                            chars[k] = " "
                self._masked[rel] = "".join(chars).split("\n")
        return self._masked[rel]

    def in_prose(self, rel, line, col):
        """True when column col of a line is inside a comment or docstring."""
        masked = self.prose_masked(rel)
        if masked is None or not 0 < line <= len(masked):
            return False
        ln = masked[line - 1]
        return col < len(ln) and ln[col] == " " and self.line_text(rel, line)[col] != " "

    def walk(self, top, exts=None, with_self=False):
        """Repo-relative paths of the files under top, sorted. This file is
        left out unless with_self is set (only R7 needs it)."""
        root = os.path.join(self.repo, top)
        if os.path.isfile(root):
            return [] if top == SELF_REL else [top]
        out = []
        for d, dirs, files in os.walk(root):
            dirs[:] = sorted(x for x in dirs if x not in PRUNE)
            for name in files:
                if exts and not name.endswith(exts):
                    continue
                rel = os.path.relpath(os.path.join(d, name), self.repo).replace(os.sep, "/")
                if with_self or rel != SELF_REL:
                    out.append(rel)
        return sorted(out)

    def grep(self, rule, files, regexes):
        for rel in files:
            for i, ln in enumerate(self.lines(rel) or (), 1):
                if any(r.search(ln) for r in regexes):
                    self.add(rule, rel, i, ln)


def is_comment(line):
    return line.lstrip().startswith("#")


def run(repo):
    a = Audit(repo)
    tests_all = a.walk("tests")
    tests_code = [p for p in tests_all if p.endswith((".sh", ".lua", ".py"))]
    tests_sh = [p for p in tests_all if p.endswith(".sh")]
    tests_py = [p for p in tests_all if p.endswith(".py")]
    top = [p for p in a.walk("tests", with_self=True) if p.count("/") == 1]

    # R1 fixed-tmp: every line, comments too; only a placeholder such as
    # <run> right before the match, inside a comment or docstring, is let go
    for rel in tests_code + a.walk("lua", (".lua",)) + a.walk("core/src", (".rs",)):
        hit = set()
        for i, ln in enumerate(a.lines(rel) or (), 1):
            for m in R1_RE.finditer(ln):
                if PLACEHOLDER_RE.search(ln, 0, m.start()) and a.in_prose(rel, i, m.start()):
                    continue
                a.add("R1-fixed-tmp", rel, i, ln)
                hit.add(i)
                break
        # string pieces joined into the path ("/" + "tmp/x", "/" .. "tmp")
        text = "\n".join(a.lines(rel) or [])
        joined = py_joined_text(text) if rel.endswith(".py") else \
            lua_joined_text(text) if rel.endswith(".lua") else None
        for line, content in joined or ():
            if line not in hit and R1_RE.search(content):
                a.add("R1-fixed-tmp", rel, line, a.line_text(rel, line) + "  (joined: " + content + ")")
                hit.add(line)

    # R2 blanket-kill: code only; comments and docstrings are prose
    def r2_hit(ln):
        return any(r.search(ln) for r in R2_RES) or kill_targets_all(ln) \
            or kill_call_targets_group(ln) or argv_kill_targets_all(ln)
    for rel in tests_all:
        lines = a.lines(rel) or []
        hits = [i for i, ln in enumerate(lines, 1) if r2_hit(ln)]
        masked = a.prose_masked(rel) if hits else None
        for i in hits:
            if masked is None or r2_hit(masked[i - 1]):
                a.add("R2-blanket-kill", rel, i, lines[i - 1])

    # R3 tmux-private
    for rel in tests_sh:
        if rel in R3_EXEMPT:
            continue
        lines = a.lines(rel) or []
        cmds = a.cmds(rel)
        issues = {}
        for c in cmds or ():
            for line, why in shell_tmux_issues(c):
                issues.setdefault(line, why)
        for line, why in pipe_tmux_issues(cmds or ()):
            issues.setdefault(line, why)
        # every way around the wrapper the lexer found also runs tmux (R3b);
        # the plain forms below may sit in a message, so they do not count
        uses = set(issues)
        for i, ln in enumerate(lines, 1):
            if not is_comment(ln) and any(r.search(ln) for r in R3A_RES):
                issues.setdefault(i, "goes around the wrapper")
        for line in sorted(issues):
            a.add("R3a-tmux-private", rel, line, issues[line] + ": " + a.line_text(rel, line))
        if cmds is not None:
            uses.update(tmux_use_lines(cmds))
            src_lib = sources(cmds, [LIB_TMUX])
            src_any = src_lib or sources(cmds, [SCREEN_LIB])
        else:  # R0 is reported; fall back to the line forms
            uses.update(i for i, ln in enumerate(lines, 1)
                        if not is_comment(ln) and R3B_USE_RE.search(ln))
            src_lib = sources_by_line(lines, [LIB_TMUX])
            src_any = src_lib or sources_by_line(lines, [SCREEN_LIB])
        first_use = min(uses) if uses else None
        if rel == "tests/" + SCREEN_LIB:
            if not src_lib:
                ln = a.line_text(rel, first_use) if first_use else ""
                a.add("R3b-tmux-private", rel, first_use or 1, "screen_lib.sh does not source "
                      + LIB_TMUX + (": " + ln.strip() if ln.strip() else ""))
        elif first_use and not src_any:
            a.add("R3b-tmux-private", rel, first_use, "runs " + T + " without sourcing "
                  + LIB_TMUX + " or " + SCREEN_LIB + ": " + a.line_text(rel, first_use).strip())
    for rel in tests_py + [p for p in tests_all if p.endswith(".lua")]:
        if rel.startswith("tests/lib/"):
            continue
        lines = a.lines(rel)
        if lines is None:
            continue
        text = "\n".join(lines)
        issues = py_tmux_issues(text) if rel.endswith(".py") else lua_tmux_issues(text)
        if issues is None:
            issues = fallback_tmux_issues(lines)
        lang = "Python" if rel.endswith(".py") else "Lua"
        seen = set()
        for line, why in issues:
            if line not in seen:
                seen.add(line)
                a.add("R3a-tmux-private", rel, line, why + " in a " + lang
                      + " test outside tests/lib/: " + a.line_text(rel, line))

    # R4 run-env
    for rel in top:
        name = rel.split("/", 1)[1]
        if not name.endswith(".sh") or name in R4_EXEMPT or rel == SELF_REL:
            continue
        cmds = a.cmds(rel)
        names = [LIB_ENV, LIB_TMUX, SCREEN_LIB]
        ok = sources(cmds, names) if cmds is not None else \
            sources_by_line(a.lines(rel) or [], names)
        if not ok:
            a.add("R4-run-env", rel, 1, "no source line naming " + LIB_ENV + ", "
                  + LIB_TMUX + " or " + SCREEN_LIB)

    # R5 no-local-notes
    a.grep("R5-no-local-notes",
           tests_all + a.walk("lua") + a.walk("core/src") + a.walk(".github") + a.walk("README.md"),
           [R5_RE])

    # R6 racy-tempfile
    a.grep("R6-racy-tempfile", tests_py, [R6_RE])

    # R7 wired: by stem, as a whole word, on run_all.sh's code lines
    run_all = a.lines("tests/run_all.sh")
    code = "\n".join(ln for ln in (run_all or ()) if not is_comment(ln))
    for rel in top:
        name = rel.split("/", 1)[1]
        stem, ext = os.path.splitext(name)
        if ext not in (".sh", ".lua", ".py") or name in R7_EXEMPT:
            continue
        if not re.search(r"(?<![\w-])" + re.escape(stem) + r"(?![\w-])", code):
            a.add("R7-wired", rel, 1, "not run by tests/run_all.sh (no word " + stem + " there)")

    # R8 exit-trap
    for rel in tests_sh:
        if rel in R8_EXEMPT:
            continue
        for c in a.cmds(rel) or ():
            if sets_exit_trap(c):
                line = effective(c.words)[0].line
                a.add("R8-exit-trap", rel, line, a.line_text(rel, line))

    # R9 run-tmp: mktemp makes its names under the run's temp dir
    for rel in tests_sh:
        if rel in R9_EXEMPT:
            continue
        seen = set()
        for c in a.cmds(rel) or ():
            hit = mktemp_issue(c)
            if hit and hit[0] not in seen:
                seen.add(hit[0])
                a.add("R9-run-tmp", rel, hit[0], hit[1] + ": " + a.line_text(rel, hit[0]))

    return a.found, len(a._lines)


# ── self-test ───────────────────────────────────────────
# Before every audit the rules are run on a small tree of probe files, kept
# here (this file is exempt from its own rules): each probe line must be
# caught by its rule (True) or not (False). A rule that stops catching what
# it is meant to catch fails the audit, so the audit can never pass by
# having gone blind.
SELF_TEST_FILES = {
    "tests/probe.py": [
        ("R2", "import os, signal, subprocess", False),
        ("R2", "os.kill" + "pg(1234, signal.SIGTERM)", True),
        ("R2", "os.kill" + "pg(os.getpgid(0), 9)", True),
        ("R2", "os.kill(-1, 9)", True),
        ("R2", "os.kill(0, 15)", True),
        ("R2", "os.kill(-pid, 9)", True),
        ("R2", "os.kill(0 - pid, 9)", True),
        ("R2", "os.kill(pid * -1, 9)", True),
        ("R2", "os.kill(int(-pid), signal.SIGTERM)", True),
        ("R2", "os.kill(os.getpgrp(), 9)", True),
        ("R2", 'subprocess.run(["kill", "-TERM", "-1234"])', True),
        ("R2", 'subprocess.run(["kill", "--", "-1234"])', True),
        ("R2", 'subprocess.run(["' + _PK + '", "-f", "x"])', True),
        ("R2", "os.kill(pid, 9)", False),
        ("R2", "os.kill(pids[-1], signal.SIGTERM)", False),
        ("R2", "os.kill(p, signal.SIGKILL)", False),
        ("R2", 'subprocess.run(["kill", "-TERM", str(pid)])', False),
        ("R2", "proc.kill()", False),
        ("R2", "# os.kill" + "pg(1, 9) in a comment is prose", False),
        ("R2", 'os.kill(int("-1"), 9)', True),
        ("R2", "pid = -os.getpid(); os.kill(pid, 9)", True),
        ("R2", "os.kill(int(s), 9)", False),
        ("R2", "n = os.getpid() - 1", False),
        ("R3", 'subprocess.run(["tm" + "ux", "kill-server"])', True),
        ("R3", 'subprocess.run(["tm" "ux", "ls"])', True),
        ("R3", 'x = "tm" + "p"', False),
        ("R1", 'open("/" + "' + TMP[1:] + '/x", "w")', True),
        ("R1", 'p = "/" + "var"', False),
    ],
    "tests/probe.lua": [
        ("R2", "vim.uv.kill(-1, 9)", True),
        ("R2", "vim.loop.kill(0, 15)", True),
        ("R2", 'vim.uv.kill(-pid, "sigterm")', True),
        ("R2", 'vim.fn.system({"kill", "-TERM", "-" .. pid})', True),
        ("R2", 'vim.fn.system({"' + _PK + '", "nvim"})', True),
        ("R2", 'vim.uv.kill(pid, "sigterm")', False),
        ("R2", "handle:kill(15)", False),
        ("R2", 'vim.uv.kill(tonumber("-1"), 15)', True),
        ("R2", "local pid = -vim.fn.getpid()", True),
        ("R3", 'vim.fn.system({"tm" .. "ux", "kill-server"})', True),
        ("R3", 'local s = "tm" .. "p"', False),
        ("R1", 'local p = "/" .. "' + TMP[1:] + '/x"', True),
    ],
    "tests/probe_kill.sh": [
        ("R2", "kill -TERM 0", True),
        ("R2", "kill -9 -1", True),
        ("R2", "kill -- -$$", True),
        ("R2", _PK + " -f nvim", True),
        ("R2", 'kill -TERM "$pid"', False),
    ],
    "tests/probe_tmp.sh": [
        ("R1", 'cp a "$R"' + TMP + "/b", False),
        ("R1", 'cp a "${R}"' + TMP + "/b", False),
        ("R1", "cp a $R" + TMP + "/b", False),
        ("R1", 'cp a "' + TMP + '/b"', True),
        ("R1", "cp a " + TMP + "/b", True),
        ("R1", "echo x > " + TMP + "/b", True),
    ],
    "tests/probe_mktemp.sh": [
        ("R9", 'x=$(timeout 5 mktemp -d "$TMPDIR/../x.XXXXXX")', True),
        ("R9", 'mktemp -d "$TMPDIR/../y.XXXXXX"', True),
        ("R9", "nice mktemp -d /var/folders/x.XXXXXX", True),
        ("R9", 'mktemp -p "$TMPDIR" ../z.XXXXXX', True),
        ("R9", 'x=$(mktemp -d "$TMPDIR/ok.XXXXXX")', False),
        ("R9", 'x=$(timeout 5 mktemp -d "$TMPDIR/ok.XXXXXX")', False),
        ("R9", 'mktemp -p "$TMPDIR" ok.XXXXXX', False),
        ("R9", "command -v mktemp", False),
        ("R9", "echo mktemp", False),
    ],
}


def self_test():
    """The probe lines the rules get wrong, as violation lines; [] when the
    rules catch exactly what they should."""
    import tempfile
    bad = []
    with tempfile.TemporaryDirectory(prefix="isolation-audit.") as tmp:
        os.makedirs(os.path.join(tmp, "tests"))
        for rel, probes in SELF_TEST_FILES.items():
            with open(os.path.join(tmp, rel), "w") as f:
                f.write("".join(text + "\n" for _, text, _ in probes))
        found, _ = run(tmp)
        hits = {(rule.split("-", 1)[0][:2], rel, line) for rule, rel, line, _ in found}
        for rel, probes in SELF_TEST_FILES.items():
            for i, (rule, text, want) in enumerate(probes, 1):
                if ((rule, rel, i) in hits) != want:
                    bad.append(f"SELF-TEST {rule} {rel}:{i}: "
                               f"{'not caught' if want else 'caught but fine'}: {text}")
    return bad


def main(argv):
    t0 = time.monotonic()
    here = os.path.dirname(os.path.abspath(__file__))
    repo = os.path.abspath(argv[1]) if len(argv) > 1 else os.path.dirname(here)
    if not os.path.isdir(os.path.join(repo, "tests")):
        print(f"isolation audit: no tests/ under {repo}", file=sys.stderr)
        return 2
    selfbad = self_test()
    for ln in selfbad:
        print(ln)
    found, nfiles = run(repo)
    found += [("SELF-TEST", "", 0, ln) for ln in selfbad]
    for rule, rel, line, text in found:
        if rule == "SELF-TEST":
            continue
        print(f"{rule} {rel}:{line}: {text}")
    if found:
        print()
        for rid in sorted({r.split("-", 1)[0][:2] for r, *_ in found}):
            print(f"  {rid}: {HINTS[rid]}")
    print(f"isolation audit: {nfiles} files read in {time.monotonic() - t0:.2f}s")
    if found:
        print(f"{len(found)} ISOLATION AUDIT VIOLATIONS")
        return 1
    print("ALL ISOLATION AUDIT CHECKS PASSED")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))

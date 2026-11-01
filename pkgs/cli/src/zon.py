# SPDX-License-Identifier: MIT
"""A reader for ZON, the Zig Object Notation of build.zig.zon.

ZON is a subset of Zig expressions. This module reads all of it that a
build.zig.zon can hold: anonymous struct literals (`.{ .a = 1 }`, read
as dicts), tuples (`.{ "a", "b" }`, read as lists), string literals,
multiline string literals (`\\\\` lines), character literals, integers
in every base, floats, enum literals (`.foo`, read as `EnumLiteral`),
`true`, `false` and `null`. Field and enum names may be quoted as
`@"name"`.
"""


class ZonError(Exception):
    pass


class EnumLiteral(str):
    """An enum literal, such as the `.name = .hello` of Zig 0.14 and later."""


_ESCAPES = {"n": "\n", "r": "\r", "t": "\t", "\\": "\\", "'": "'", '"': '"'}


class _Reader:
    def __init__(self, text):
        self.text = text
        self.pos = 0

    def error(self, message):
        line = self.text.count("\n", 0, self.pos) + 1
        column = self.pos - (self.text.rfind("\n", 0, self.pos) + 1) + 1
        raise ZonError(f"line {line}, column {column}: {message}")

    def skip(self):
        while self.pos < len(self.text):
            c = self.text[self.pos]
            if c in " \t\r\n":
                self.pos += 1
            elif self.text.startswith("//", self.pos):
                end = self.text.find("\n", self.pos)
                self.pos = len(self.text) if end < 0 else end + 1
            else:
                break

    def peek(self, offset=0):
        i = self.pos + offset
        return self.text[i] if i < len(self.text) else ""

    def expect(self, s):
        self.skip()
        if not self.text.startswith(s, self.pos):
            self.error(f"expected {s!r}")
        self.pos += len(s)

    def name(self):
        """An identifier, or a quoted @"identifier"."""
        if self.peek() == "@" and self.peek(1) == '"':
            self.pos += 1
            return self.string()
        start = self.pos
        while self.peek().isalnum() or self.peek() == "_":
            self.pos += 1
        if start == self.pos:
            self.error("expected a name")
        return self.text[start : self.pos]

    def escape(self):
        c = self.peek()
        self.pos += 1
        if c in _ESCAPES:
            return _ESCAPES[c]
        if c == "x":
            digits = self.text[self.pos : self.pos + 2]
            self.pos += 2
            return chr(int(digits, 16))
        if c == "u" and self.peek() == "{":
            end = self.text.find("}", self.pos)
            if end < 0:
                self.error("unterminated \\u{} escape")
            code = int(self.text[self.pos + 1 : end], 16)
            self.pos = end + 1
            return chr(code)
        self.error(f"unknown escape \\{c}")

    def string(self):
        self.pos += 1  # the opening quote
        out = []
        while True:
            c = self.peek()
            if c == "":
                self.error("unterminated string")
            self.pos += 1
            if c == '"':
                return "".join(out)
            if c == "\n":
                self.error("newline in a string literal")
            out.append(self.escape() if c == "\\" else c)

    def multiline(self):
        lines = []
        while True:
            self.skip_blanks()
            if not self.text.startswith("\\\\", self.pos):
                break
            self.pos += 2
            end = self.text.find("\n", self.pos)
            end = len(self.text) if end < 0 else end
            lines.append(self.text[self.pos : end].rstrip("\r"))
            self.pos = end
        return "\n".join(lines)

    def skip_blanks(self):
        while self.peek() in (" ", "\t", "\r", "\n") and self.peek() != "":
            self.pos += 1

    def char(self):
        self.pos += 1
        c = self.peek()
        self.pos += 1
        value = self.escape() if c == "\\" else c
        if self.peek() != "'":
            self.error("unterminated character literal")
        self.pos += 1
        return ord(value)

    def number(self):
        start = self.pos
        if self.peek() == "-":
            self.pos += 1
        while self.peek().isalnum() or self.peek() in "_.+-":
            if self.peek() in "+-" and self.text[self.pos - 1] not in "eEpP":
                break
            self.pos += 1
        literal = self.text[start : self.pos].replace("_", "")
        negative = literal.startswith("-")
        body = literal[1:] if negative else literal
        try:
            if body[:2] in ("0x", "0o", "0b") and not any(c in body for c in ".pP"):
                value = int(body, 0)
            elif any(c in body for c in ".eEpP") and not body.startswith("0x"):
                value = float(body)
            elif body.startswith("0x"):
                value = float.fromhex(body)
            else:
                value = int(body, 10)
        except ValueError:
            self.error(f"bad number {literal!r}")
        return -value if negative else value

    def value(self):
        self.skip()
        c = self.peek()
        if c == ".":
            if self.peek(1) == "{":
                self.pos += 2
                return self.aggregate()
            self.pos += 1
            return EnumLiteral(self.name())
        if c == '"':
            return self.string()
        if c == "\\" and self.peek(1) == "\\":
            return self.multiline()
        if c == "'":
            return self.char()
        if c.isdigit() or (c == "-" and self.peek(1).isdigit()):
            return self.number()
        if c.isalpha() or c == "_":
            word = self.name()
            if word in ("true", "false"):
                return word == "true"
            if word == "null":
                return None
            if word in ("inf", "nan"):
                return float(word)
            self.error(f"unexpected identifier {word!r}")
        self.error("expected a value")

    def is_field(self):
        """Whether `.name =` starts here, which makes the aggregate a struct."""
        saved = self.pos
        try:
            self.skip()
            if self.peek() != "." or self.peek(1) == "{":
                return False
            self.pos += 1
            self.name()
            self.skip()
            return self.peek() == "=" and self.peek(1) != "="
        except ZonError:
            return False
        finally:
            self.pos = saved

    def aggregate(self):
        self.skip()
        if self.peek() == "}":
            self.pos += 1
            return {}
        if self.is_field():
            result = {}
            while True:
                self.skip()
                if self.peek() == "}":
                    self.pos += 1
                    return result
                self.expect(".")
                key = self.name()
                self.expect("=")
                if key in result:
                    self.error(f"duplicate field {key!r}")
                result[key] = self.value()
                self.skip()
                if self.peek() == ",":
                    self.pos += 1
                elif self.peek() != "}":
                    self.error("expected ',' or '}'")
        result = []
        while True:
            self.skip()
            if self.peek() == "}":
                self.pos += 1
                return result
            result.append(self.value())
            self.skip()
            if self.peek() == ",":
                self.pos += 1
            elif self.peek() != "}":
                self.error("expected ',' or '}'")


def loads(text):
    reader = _Reader(text)
    value = reader.value()
    reader.skip()
    if reader.pos != len(text):
        reader.error("trailing text after the value")
    return value


def load(path):
    with open(path, encoding="utf-8") as f:
        try:
            return loads(f.read())
        except ZonError as e:
            raise ZonError(f"{path}: {e}") from None

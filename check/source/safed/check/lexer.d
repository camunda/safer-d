/// Splits D source into lines the rules can match on safely: each line's
/// code with comments removed and string/character literal contents
/// emptied (`"x"` becomes `""`), and whether the line carries a comment.
///
/// It is a lexer, not a parser: it knows D's comment forms (`//`, `/* */`,
/// nesting `/+ +/`) and literal forms (`"..."` with escapes, `r"..."`,
/// `` `...` ``, `'c'`, `q"(...)"`-style delimited strings), across lines.
/// Token strings (`q{...}`) stay code, since their contents are D tokens.
/// That is enough for the rules: a `@trusted` in a comment or a `catch` in
/// a string can no longer match.
module safed.check.lexer;

@safe:

/// One source line, as the rules see it.
struct Line
{
    /// 1-based line number.
    size_t number;
    /// The line as written.
    string raw;
    /// The code: comments removed, literal contents emptied.
    string code;
    /// The text of the comments on this line (without the markers).
    string comment;
    /// Whether any comment touches this line.
    bool hasComment;
    /// A doc comment (`///`, `/**`, `/++`) touches this line.
    bool hasDocComment;
    /// The contents of string literals inside `mixin(...)` on this line:
    /// code that the compiler will see, so the escape rules read it too.
    string mixinText;

    /// The code plus any mixed-in string text: what the escape rules match.
    string escapeText() const pure
    {
        return mixinText.length ? code ~ " " ~ mixinText : code;
    }

    /// Comment and whitespace only (at least one comment).
    bool commentOnly() const pure { return hasComment && isBlank(code); }

    /// Nothing but whitespace.
    bool blank() const pure { return isBlank(raw); }
}

/// True when `s` is empty or only spaces and tabs (and a stray `\r`).
bool isBlank(scope const(char)[] s) pure nothrow @nogc
{
    foreach (c; s)
        if (c != ' ' && c != '\t' && c != '\r') return false;
    return true;
}

private enum State { code, lineComment, blockComment, nestComment, str, rawStr, chr, delimStr }

private bool isIdent(char c) pure nothrow @nogc
{
    return c == '_' || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9');
}

/// Lex `text` into lines.
Line[] lex(string text) pure
{
    import std.array : appender;

    Line[] lines;
    auto code = appender!string;
    auto comment = appender!string;
    auto mixed = appender!string;
    bool hasComment, hasDoc;
    size_t lineStart, number = 1;

    State st = State.code;
    int nest;               // /+ +/ depth
    char rawClose;          // closing char for r"..." (") or `...` (`)
    char delimClose;        // closing char of q"(...)" etc.
    string delimIdent;      // closing identifier of q"EOS ... EOS"
    bool afterMixin;        // just read the keyword `mixin`
    int mixinDepth;         // parentheses open inside `mixin(`

    // Literal text inside `mixin(...)` is kept: it is code the compiler sees.
    void literal(char ch)
    {
        if (mixinDepth > 0) mixed ~= ch;
    }

    void endLine(size_t end) @safe
    {
        auto raw = text[lineStart .. end];
        if (raw.length && raw[$ - 1] == '\r') raw = raw[0 .. $ - 1];
        lines ~= Line(number, raw, code[].idup, comment[].idup, hasComment, hasDoc, mixed[].idup);
        code = appender!string;
        comment = appender!string;
        mixed = appender!string;
        // A comment that runs on from the line before touches this one too.
        hasComment = st == State.blockComment || st == State.nestComment;
        hasDoc = false;
        number++;
    }

    size_t i;
    while (i < text.length)
    {
        immutable c = text[i];
        immutable n = i + 1 < text.length ? text[i + 1] : '\0';
        if (c == '\n')
        {
            if (st == State.lineComment) st = State.code;
            endLine(i);
            lineStart = i + 1;
            i++;
            // A heredoc-style q"EOS" closes at a line that starts with EOS.
            if (st == State.delimStr && delimIdent.length)
            {
                auto rest = text[i .. $];
                if (rest.length >= delimIdent.length + 1 && rest[0 .. delimIdent.length] == delimIdent
                    && rest[delimIdent.length] == '"')
                {
                    code ~= '"';
                    i += delimIdent.length + 1;
                    st = State.code;
                }
            }
            continue;
        }
        final switch (st)
        {
        case State.code:
            if (c == '/' && n == '/')
            {
                st = State.lineComment;
                hasComment = true;
                if (i + 2 < text.length && text[i + 2] == '/') hasDoc = true;
                i += 2;
                continue;
            }
            if (c == '/' && n == '*')
            {
                st = State.blockComment;
                hasComment = true;
                if (i + 2 < text.length && text[i + 2] == '*'
                    && !(i + 3 < text.length && text[i + 3] == '/')) hasDoc = true;
                i += 2;
                continue;
            }
            if (c == '/' && n == '+')
            {
                st = State.nestComment;
                nest = 1;
                hasComment = true;
                if (i + 2 < text.length && text[i + 2] == '+'
                    && !(i + 3 < text.length && text[i + 3] == '/')) hasDoc = true;
                i += 2;
                continue;
            }
            immutable prevIdent = i > 0 && isIdent(text[i - 1]);
            if ((c == 'r' || c == 'x') && n == '"' && !prevIdent)
            {
                // r"raw" has no escapes; x"hex" never holds a quote.
                code ~= c;
                code ~= '"';
                st = State.rawStr;
                rawClose = '"';
                i += 2;
                continue;
            }
            if (c == 'q' && n == '"' && !prevIdent && i + 2 < text.length)
            {
                immutable o = text[i + 2];
                code ~= "q\"";
                st = State.delimStr;
                delimIdent = null;
                if (o == '(') delimClose = ')';
                else if (o == '[') delimClose = ']';
                else if (o == '{') delimClose = '}';
                else if (o == '<') delimClose = '>';
                else if (isIdent(o))
                {
                    // q"EOS\n...\nEOS"
                    size_t j = i + 2;
                    while (j < text.length && isIdent(text[j])) j++;
                    delimIdent = text[i + 2 .. j];
                    delimClose = '\0';
                    i = j;
                    continue;
                }
                else delimClose = o;
                i += 3;
                continue;
            }
            if (c == '"')
            {
                code ~= '"';
                st = State.str;
                i++;
                continue;
            }
            if (c == '`')
            {
                code ~= '`';
                st = State.rawStr;
                rawClose = '`';
                i++;
                continue;
            }
            if (c == '\'')
            {
                code ~= '\'';
                st = State.chr;
                i++;
                continue;
            }
            if (c == 'm' && !prevIdent && text.length - i >= 5 && text[i .. i + 5] == "mixin"
                && (i + 5 == text.length || !isIdent(text[i + 5])))
            {
                code ~= "mixin";
                afterMixin = true;
                i += 5;
                continue;
            }
            if (c == '(')
            {
                if (mixinDepth > 0) mixinDepth++;
                else if (afterMixin) mixinDepth = 1;
            }
            else if (c == ')' && mixinDepth > 0) mixinDepth--;
            if (c != ' ' && c != '\t' && c != '\r') afterMixin = false;
            code ~= c;
            i++;
            continue;
        case State.lineComment:
            comment ~= c;
            i++;
            continue;
        case State.blockComment:
            if (c == '*' && n == '/')
            {
                st = State.code;
                code ~= ' ';
                i += 2;
                continue;
            }
            comment ~= c;
            i++;
            continue;
        case State.nestComment:
            if (c == '/' && n == '+') { nest++; i += 2; continue; }
            if (c == '+' && n == '/')
            {
                nest--;
                i += 2;
                if (nest == 0)
                {
                    st = State.code;
                    code ~= ' ';
                }
                continue;
            }
            comment ~= c;
            i++;
            continue;
        case State.str:
            if (c == '\\') { i += n == '\n' ? 1 : 2; continue; }
            if (c == '"')
            {
                code ~= '"';
                st = State.code;
            }
            else literal(c);
            i++;
            continue;
        case State.rawStr:
            if (c == rawClose)
            {
                code ~= c;
                st = State.code;
            }
            else literal(c);
            i++;
            continue;
        case State.chr:
            if (c == '\\') { i += n == '\n' ? 1 : 2; continue; }
            if (c == '\'')
            {
                code ~= '\'';
                st = State.code;
            }
            i++;
            continue;
        case State.delimStr:
            if (delimClose != '\0' && c == delimClose && n == '"')
            {
                code ~= '"';
                st = State.code;
                i += 2;
                continue;
            }
            literal(c);
            i++;
            continue;
        }
    }
    if (lineStart < text.length || !lines.length) endLine(text.length);
    return lines;
}

unittest
{
    auto ls = lex("int a; // @trusted here\n/* a\n @system */ int b = 1;\nauto s = \"catch (Exception)\";\n");
    assert(ls.length == 4);
    assert(ls[0].code == "int a; " && ls[0].hasComment && !ls[0].commentOnly);
    assert(ls[0].comment == " @trusted here");
    assert(ls[1].commentOnly && ls[1].code == "");
    assert(ls[2].code == "  int b = 1;" && ls[2].hasComment && !ls[2].commentOnly);
    assert(ls[3].code == "auto s = \"\";" && !ls[3].hasComment);
}

unittest
{
    auto ls = lex("auto s = \"a\\\"b\"; char c = '\\''; auto r = r\"x\\\"; auto t = `y\"`;");
    assert(ls[0].code == "auto s = \"\"; char c = ''; auto r = r\"\"; auto t = ``;", ls[0].code);
}

unittest
{
    // Nested /+ +/, doc comments, multi-line strings.
    auto ls = lex("/+ a /+ b +/ c +/ x;\n/// doc\nauto s = \"line1\nline2 @trusted\";\nq{ a.b }");
    assert(ls[0].code == "  x;" && ls[0].hasComment && !ls[0].hasDocComment);
    assert(ls[1].hasDocComment && ls[1].commentOnly);
    assert(ls[2].code == "auto s = \"");
    assert(ls[3].code == "\";");
    assert(ls[4].code == "q{ a.b }");
}

unittest
{
    auto ls = lex("auto a = q\"(x\"y)\"; auto b = q\"EOS\nhello @system\nEOS\";\nint z;");
    assert(ls[0].code == "auto a = q\"\"; auto b = q\"", ls[0].code);
    assert(ls[1].code == "");
    assert(ls[2].code == "\";", ls[2].code);
    assert(ls[3].code == "int z;");
}

unittest
{
    // String mixins are code: their text is kept for the escape rules.
    auto ls = lex("mixin(\"void f() @trusted { }\");\nauto s = \"@trusted\";\n"
        ~ "mixin(\"int \" ~ name ~ \"() @system\",\n  \"__gshared int x;\");\nmixin template T() {}\nf(\"x\");");
    assert(ls[0].mixinText == "void f() @trusted { }" && ls[0].code == "mixin(\"\");");
    assert(ls[1].mixinText == "" && ls[1].escapeText == ls[1].code);
    assert(ls[2].mixinText == "int () @system", ls[2].mixinText);
    assert(ls[3].mixinText == "__gshared int x;");
    assert(ls[4].mixinText == "" && ls[5].mixinText == "");
}

unittest
{
    // A backslash at the end of a line inside a string keeps the count.
    auto ls = lex("auto s = \"a\\\nb\";\nint y;");
    assert(ls.length == 3 && ls[2].code == "int y;");
    assert(lex("").length == 1);
    assert(lex("a\r\nb").length == 2 && lex("a\r\nb")[0].raw == "a");
    assert(isBlank(" \t") && !isBlank(" x"));
}

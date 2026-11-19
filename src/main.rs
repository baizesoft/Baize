use std::{env, fs, process};

#[derive(Clone, Debug, PartialEq)]
enum Token {
    Name(String),
    Text(Vec<u8>),
    Number(i64),
    Op(String),
    Equal,
    LParen,
    RParen,
    LBrace,
    RBrace,
    LBracket,
    RBracket,
    Comma,
    End,
    Eof,
}
#[derive(Clone, Debug)]
enum Expr {
    Number(i64),
    Bool(bool),
    Name(String),
    Text(Vec<u8>),
    Index(String, Box<Expr>),
    Binary(Box<Expr>, String, Box<Expr>),
    Call(String, Vec<Expr>),
}
#[derive(Clone, Debug)]
enum Stmt {
    Let(String, Expr),
    Assign(String, Expr),
    ByteArray(String, usize),
    StoreByte(String, Expr, Expr),
    Print(Expr),
    PrintText(Vec<u8>),
    Return(Expr),
    If(Expr, Vec<Stmt>, Vec<Stmt>),
    While(Expr, Vec<Stmt>),
}
#[derive(Clone, Debug)]
struct Function {
    name: String,
    params: Vec<String>,
    body: Vec<Stmt>,
}
#[derive(Clone, Debug)]
struct Program {
    functions: Vec<Function>,
    body: Vec<Stmt>,
}

fn main() {
    let args: Vec<String> = env::args().collect();
    if args.len() != 3 {
        eprintln!("usage: bzseed <source.bz> <output.c>");
        process::exit(2);
    }
    let source = fs::read_to_string(&args[1]).unwrap_or_else(|e| {
        eprintln!("read error: {}", e);
        process::exit(1)
    });
    match compile(&source) {
        Ok(c) => fs::write(&args[2], c).unwrap_or_else(|e| {
            eprintln!("write error: {}", e);
            process::exit(1)
        }),
        Err(e) => {
            eprintln!("{}", e);
            process::exit(1);
        }
    }
}
fn zh(s: &str) -> String {
    format!("\u{7f16}\u{8bd1}\u{9519}\u{8bef}\u{ff1a}{}", s)
}
fn is_word(s: &str, cps: &[u32]) -> bool {
    s.chars().eq(cps.iter().filter_map(|x| char::from_u32(*x)))
}
fn lex(src: &str) -> Result<Vec<Token>, String> {
    let ch: Vec<char> = src.trim_start_matches('\u{feff}').chars().collect();
    let (mut i, mut out) = (0usize, Vec::new());
    while i < ch.len() {
        let c = ch[i];
        if c == '\n' {
            out.push(Token::End);
            i += 1;
            continue;
        }
        if c.is_whitespace() {
            i += 1;
            continue;
        }
        if c == '#' {
            while i < ch.len() && ch[i] != '\n' {
                i += 1;
            }
            continue;
        }
        if c.is_ascii_digit() {
            let st = i;
            while i < ch.len() && ch[i].is_ascii_digit() {
                i += 1;
            }
            let n: String = ch[st..i].iter().collect();
            out.push(Token::Number(
                n.parse()
                    .map_err(|_| zh("\u{6574}\u{6570}\u{6ea2}\u{51fa}"))?,
            ));
            continue;
        }
        if c == '\u{201c}' || c == '"' {
            let end = if c == '\u{201c}' { '\u{201d}' } else { '"' };
            i += 1;
            let mut s = String::new();
            while i < ch.len() && ch[i] != end {
                if ch[i] == '\\' && i + 1 < ch.len() {
                    i += 1;
                    s.push(match ch[i] {
                        'n' => '\n',
                        't' => '\t',
                        x => x,
                    });
                } else {
                    s.push(ch[i]);
                }
                i += 1;
            }
            if i == ch.len() {
                return Err(zh("\u{5b57}\u{7b26}\u{4e32}\u{672a}\u{95ed}\u{5408}"));
            }
            i += 1;
            out.push(Token::Text(s.into_bytes()));
            continue;
        }
        if c == '_' || c.is_alphabetic() {
            let st = i;
            i += 1;
            while i < ch.len() && (ch[i] == '_' || ch[i].is_alphanumeric()) {
                i += 1;
            }
            out.push(Token::Name(ch[st..i].iter().collect()));
            continue;
        }
        if i + 1 < ch.len() {
            let op = match (c, ch[i + 1]) {
                ('=', '=') => Some("=="),
                ('!', '=') => Some("!="),
                ('<', '=') => Some("<="),
                ('>', '=') => Some(">="),
                _ => None,
            };
            if let Some(x) = op {
                out.push(Token::Op(x.into()));
                i += 2;
                continue;
            }
        }
        let token = match c {
            '+' | '-' | '*' | '/' | '<' | '>' => Token::Op(c.to_string()),
            '=' => Token::Equal,
            '(' | '\u{ff08}' => Token::LParen,
            ')' | '\u{ff09}' => Token::RParen,
            '{' => Token::LBrace,
            '}' => Token::RBrace,
            '[' => Token::LBracket,
            ']' => Token::RBracket,
            ',' | '\u{ff0c}' => Token::Comma,
            ';' | '\u{ff1b}' => Token::End,
            _ => return Err(zh("\u{65e0}\u{6cd5}\u{8bc6}\u{522b}\u{5b57}\u{7b26}")),
        };
        out.push(token);
        i += 1;
    }
    out.push(Token::Eof);
    Ok(out)
}
struct Parser {
    t: Vec<Token>,
    i: usize,
}
impl Parser {
    fn peek(&self) -> &Token {
        &self.t[self.i]
    }
    fn take(&mut self) -> Token {
        let x = self.t[self.i].clone();
        self.i += 1;
        x
    }
    fn is(&self, c: &[u32]) -> bool {
        matches!(self.peek(),Token::Name(s) if is_word(s,c))
    }
    fn need(&mut self, x: Token, msg: &str) -> Result<(), String> {
        if *self.peek() == x {
            self.take();
            Ok(())
        } else {
            Err(zh(msg))
        }
    }
    fn name(&mut self, msg: &str) -> Result<String, String> {
        match self.take() {
            Token::Name(s) => Ok(s),
            _ => Err(zh(msg)),
        }
    }
    fn ends(&mut self) {
        while *self.peek() == Token::End {
            self.take();
        }
    }
    fn parse(&mut self) -> Result<Program, String> {
        let (mut fs, mut body) = (Vec::new(), Vec::new());
        self.ends();
        while *self.peek() != Token::Eof {
            if self.is(&[0x51fd, 0x6570]) {
                fs.push(self.function()?);
            } else {
                body.push(self.stmt()?);
            }
            self.ends();
        }
        if fs.is_empty() && body.is_empty() {
            return Err(zh("\u{7a7a}\u{7a0b}\u{5e8f}"));
        }
        Ok(Program {
            functions: fs,
            body,
        })
    }
    fn function(&mut self) -> Result<Function, String> {
        self.take();
        let n = self.name("\u{51fd}\u{6570}\u{540d}\u{9519}\u{8bef}")?;
        self.need(
            Token::LParen,
            "\u{51fd}\u{6570}\u{9700}\u{8981}\u{53c2}\u{6570}\u{62ec}\u{53f7}",
        )?;
        let mut ps = Vec::new();
        if *self.peek() != Token::RParen {
            loop {
                ps.push(self.name("\u{53c2}\u{6570}\u{9700}\u{8981}\u{540d}\u{79f0}")?);
                if *self.peek() != Token::Comma {
                    break;
                }
                self.take();
            }
        }
        self.need(
            Token::RParen,
            "\u{53c2}\u{6570}\u{62ec}\u{53f7}\u{672a}\u{95ed}\u{5408}",
        )?;
        let b = self.block()?;
        Ok(Function {
            name: n,
            params: ps,
            body: b,
        })
    }
    fn block(&mut self) -> Result<Vec<Stmt>, String> {
        self.need(Token::LBrace, "\u{9700}\u{8981} { ")?;
        self.ends();
        let mut b = Vec::new();
        while *self.peek() != Token::RBrace {
            if *self.peek() == Token::Eof {
                return Err(zh("\u{4ee3}\u{7801}\u{5757}\u{672a}\u{95ed}\u{5408}"));
            }
            b.push(self.stmt()?);
            self.ends();
        }
        self.take();
        Ok(b)
    }
    fn stmt(&mut self) -> Result<Stmt, String> {
        if self.is(&[0x8f93, 0x51fa]) {
            self.take();
            self.need(Token::LParen, "\u{8f93}\u{51fa}\u{9700}\u{8981} (")?;
            let s = if let Token::Text(b) = self.peek().clone() {
                self.take();
                Stmt::PrintText(b)
            } else {
                Stmt::Print(self.expr(0)?)
            };
            self.need(
                Token::RParen,
                "\u{8f93}\u{51fa}\u{53c2}\u{6570}\u{672a}\u{95ed}",
            )?;
            return Ok(s);
        }
        if self.is(&[0x5b57, 0x8282, 0x6570, 0x7ec4]) {
            self.take();
            let n = self.name("\u{6570}\u{7ec4}\u{9700}\u{8981}\u{540d}\u{79f0}")?;
            self.need(Token::LBracket, "\u{9700}\u{8981} [")?;
            let cap = match self.take() {
                Token::Number(n) if n > 0 => n as usize,
                _ => {
                    return Err(zh(
                        "\u{6570}\u{7ec4}\u{957f}\u{5ea6}\u{9700}\u{6b63}\u{6574}\u{6570}",
                    ))
                }
            };
            self.need(Token::RBracket, "\u{9700}\u{8981} ]")?;
            return Ok(Stmt::ByteArray(n, cap));
        }
        if self.is(&[0x6574, 0x6570]) || self.is(&[0x5e03, 0x5c14]) {
            self.take();
            let n = self.name("\u{58f0}\u{660e}\u{9700}\u{8981}\u{540d}\u{79f0}")?;
            self.need(Token::Equal, "\u{58f0}\u{660e}\u{9700}\u{8981} =")?;
            return Ok(Stmt::Let(n, self.expr(0)?));
        }
        if self.is(&[0x8fd4, 0x56de]) {
            self.take();
            return Ok(Stmt::Return(self.expr(0)?));
        }
        if self.is(&[0x5f53]) {
            self.take();
            let c = self.cond()?;
            return Ok(Stmt::While(c, self.block()?));
        }
        if self.is(&[0x5982, 0x679c]) {
            self.take();
            let c = self.cond()?;
            let a = self.block()?;
            self.ends();
            let b = if self.is(&[0x5426, 0x5219]) {
                self.take();
                self.block()?
            } else {
                Vec::new()
            };
            return Ok(Stmt::If(c, a, b));
        }
        if let Token::Name(n) = self.peek().clone() {
            if self.t.get(self.i + 1) == Some(&Token::Equal) {
                self.take();
                self.take();
                return Ok(Stmt::Assign(n, self.expr(0)?));
            }
        }
        if let Token::Name(n) = self.peek().clone() {
            if self.t.get(self.i + 1) == Some(&Token::LBracket) {
                self.take();
                self.take();
                let ix = self.expr(0)?;
                self.need(
                    Token::RBracket,
                    "\u{6570}\u{7ec4}\u{7d22}\u{5f15}\u{9700}\u{8981} ]",
                )?;
                self.need(
                    Token::Equal,
                    "\u{6570}\u{7ec4}\u{8d4b}\u{503c}\u{9700}\u{8981} =",
                )?;
                return Ok(Stmt::StoreByte(n, ix, self.expr(0)?));
            }
        }
        Err(zh(&format!(
            "\u{65e0}\u{6cd5}\u{8bc6}\u{522b}\u{8bed}\u{53e5}，\u{8bb0}\u{53f7}\u{4f4d}\u{7f6e} {}：{:?}",
            self.i,
            self.peek()
        )))
    }
    fn cond(&mut self) -> Result<Expr, String> {
        self.need(Token::LParen, "\u{6761}\u{4ef6}\u{9700}\u{8981} (")?;
        let e = self.expr(0)?;
        self.need(Token::RParen, "\u{6761}\u{4ef6}\u{9700}\u{8981} )")?;
        Ok(e)
    }
    fn expr(&mut self, min: u8) -> Result<Expr, String> {
        let mut a = match self.take() {
            Token::Number(n) => Expr::Number(n),
            Token::Text(bytes) => Expr::Text(bytes),
            Token::Name(n) if is_word(&n, &[0x771f]) => Expr::Bool(true),
            Token::Name(n) if is_word(&n, &[0x5047]) => Expr::Bool(false),
            Token::Name(n) if *self.peek() == Token::LParen => {
                self.take();
                let mut args = Vec::new();
                if *self.peek() != Token::RParen {
                    loop {
                        args.push(self.expr(0)?);
                        if *self.peek() != Token::Comma {
                            break;
                        }
                        self.take();
                    }
                }
                self.need(
                    Token::RParen,
                    "\u{8c03}\u{7528}\u{53c2}\u{6570}\u{672a}\u{95ed}",
                )?;
                Expr::Call(n, args)
            }
            Token::Name(n) if *self.peek() == Token::LBracket => {
                self.take();
                let ix = self.expr(0)?;
                self.need(Token::RBracket, "\u{9700}\u{8981} ]")?;
                Expr::Index(n, Box::new(ix))
            }
            Token::Name(n) => Expr::Name(n),
            Token::Op(o) if o == "-" => Expr::Binary(
                Box::new(Expr::Number(0)),
                "-".into(),
                Box::new(self.expr(6)?),
            ),
            Token::LParen => {
                let e = self.expr(0)?;
                self.need(
                    Token::RParen,
                    "\u{8868}\u{8fbe}\u{5f0f}\u{62ec}\u{53f7}\u{672a}\u{95ed}",
                )?;
                e
            }
            _ => return Err(zh("\u{9700}\u{8981}\u{8868}\u{8fbe}\u{5f0f}")),
        };
        loop {
            let o = match self.peek() {
                Token::Op(s) => s.clone(),
                _ => break,
            };
            let p = match o.as_str() {
                "==" | "!=" | "<" | ">" | "<=" | ">=" => 0,
                "+" | "-" => 2,
                "*" | "/" => 4,
                _ => break,
            };
            if p < min {
                break;
            }
            self.take();
            let b = self.expr(p + 1)?;
            a = Expr::Binary(Box::new(a), o, Box::new(b));
        }
        Ok(a)
    }
}
fn cname(s: &str) -> String {
    let mut x = String::from("v");
    for b in s.as_bytes() {
        x.push_str(&format!("_{:02x}", b));
    }
    x
}
fn c_string(bytes: &[u8]) -> String {
    let mut s = String::from("\"");
    for b in bytes {
        s.push_str(&format!("\\{:03o}", b));
    }
    s.push('"');
    s
}
fn ce(e: &Expr) -> String {
    match e {
        Expr::Number(n) => n.to_string(),
        Expr::Bool(b) => if *b { "1" } else { "0" }.into(),
        Expr::Name(n) => cname(n),
        Expr::Text(bytes) => c_string(bytes),
        Expr::Index(n, ix) => format!("{}[{}]", cname(n), ce(ix)),
        Expr::Binary(a, o, b) => format!("({} {} {})", ce(a), o, ce(b)),
        Expr::Call(n, a) => {
            let mut args = a.iter().map(ce).collect::<Vec<_>>();
            if is_word(n, &[0x6587, 0x4ef6, 0x8bfb, 0x53d6])
                || is_word(n, &[0x6587, 0x4ef6, 0x5199, 0x5165])
            {
                if let Some(first) = args.first_mut() {
                    *first = format!("(const char *)({})", first);
                }
            }
            let fun = if is_word(n, &[0x6587, 0x4ef6, 0x8bfb, 0x53d6]) {
                "bz_read".into()
            } else if is_word(n, &[0x6587, 0x4ef6, 0x5199, 0x5165]) {
                "bz_write".into()
            } else if is_word(n, &[0x53c2, 0x6570, 0x6570, 0x91cf]) {
                "bz_arg_count".into()
            } else if is_word(n, &[0x53c2, 0x6570, 0x8bfb, 0x53d6]) {
                "bz_arg_read".into()
            } else {
                cname(n)
            };
            format!("{}({})", fun, args.join(", "))
        }
    }
}
fn cs(s: &Stmt, d: usize) -> String {
    let p = " ".repeat(d);
    let mut o = String::new();
    match s {
        Stmt::Let(n, e) => o.push_str(&format!("{}int64_t {} = {};\n", p, cname(n), ce(e))),
        Stmt::Assign(n, e) => o.push_str(&format!("{}{} = {};\n", p, cname(n), ce(e))),
        Stmt::ByteArray(n, cap) => o.push_str(&format!(
            "{}unsigned char {}[{}] = {{0}};\n",
            p,
            cname(n),
            cap
        )),
        Stmt::StoreByte(n, ix, e) => o.push_str(&format!(
            "{}{}[{}] = (unsigned char)({});\n",
            p,
            cname(n),
            ce(ix),
            ce(e)
        )),
        Stmt::Print(e) => o.push_str(&format!(
            "{}printf(\"%lld\\n\", (long long)({}));\n",
            p,
            ce(e)
        )),
        Stmt::PrintText(b) => {
            o.push_str(&format!("{}{{ static const unsigned char s[] = {{", p));
            for (i, x) in b.iter().enumerate() {
                if i > 0 {
                    o.push(',');
                }
                o.push_str(&x.to_string());
            }
            o.push_str("}; fwrite(s, 1, sizeof s, stdout); putchar('\\n'); }\n");
        }
        Stmt::Return(e) => o.push_str(&format!("{}return {};\n", p, ce(e))),
        Stmt::If(c, a, b) => {
            o.push_str(&format!("{}if ({}) {{\n", p, ce(c)));
            for x in a {
                o.push_str(&cs(x, d + 2));
            }
            o.push_str(&format!("{}}}", p));
            if !b.is_empty() {
                o.push_str(" else {\n");
                for x in b {
                    o.push_str(&cs(x, d + 2));
                }
                o.push_str(&format!("{}}}", p));
            }
            o.push('\n');
        }
        Stmt::While(c, b) => {
            o.push_str(&format!("{}while ({}) {{\n", p, ce(c)));
            for x in b {
                o.push_str(&cs(x, d + 2));
            }
            o.push_str(&format!("{}}}\n", p));
        }
    }
    o
}
fn ends_return(b: &[Stmt]) -> bool {
    match b.last() {
        Some(Stmt::Return(_)) => true,
        Some(Stmt::If(_, a, z)) => !z.is_empty() && ends_return(a) && ends_return(z),
        _ => false,
    }
}
fn compile(src: &str) -> Result<String, String> {
    let mut p = Parser { t: lex(src)?, i: 0 };
    let pr = p.parse()?;
    let mut c = String::from("#include <stdio.h>\n#include <stdint.h>\n#include <string.h>\n");
    c.push_str("static int64_t bz_read(const char *p, unsigned char *b, int64_t n) { if (n < 0) return -1; FILE *f = fopen(p, \"rb\"); if (!f) return -1; size_t k = fread(b, 1, (size_t)n, f); int e = ferror(f); fclose(f); return e ? -1 : (int64_t)k; }\n");
    c.push_str("static int64_t bz_write(const char *p, const unsigned char *b, int64_t n) { if (n < 0) return -1; FILE *f = fopen(p, \"wb\"); if (!f) return -1; size_t k = fwrite(b, 1, (size_t)n, f); int e = ferror(f); fclose(f); return e || (int64_t)k != n ? -1 : (int64_t)k; }\n");
    c.push_str("static int bz_argc; static char **bz_argv;\n");
    c.push_str(
        "static int64_t bz_arg_count(void) { return bz_argc > 0 ? (int64_t)bz_argc - 1 : 0; }\n",
    );
    c.push_str("static int64_t bz_arg_read(int64_t i, unsigned char *b, int64_t cap) { if (i < 0 || i >= bz_arg_count() || cap <= 0) return -1; const char *s = bz_argv[i + 1]; size_t n = strlen(s); if (n >= (size_t)cap) n = (size_t)cap - 1; memcpy(b, s, n); b[n] = 0; return (int64_t)n; }\n");
    for s in &pr.body {
        match s {
            Stmt::ByteArray(n, cap) => c.push_str(&format!(
                "static unsigned char {}[{}] = {{0}};\n",
                cname(n),
                cap
            )),
            Stmt::Let(n, e) if matches!(e, Expr::Number(_) | Expr::Bool(_)) => {
                c.push_str(&format!("static int64_t {} = {};\n", cname(n), ce(e)))
            }
            _ => {}
        }
    }
    for f in &pr.functions {
        let args = f
            .params
            .iter()
            .map(|n| format!("int64_t {}", cname(n)))
            .collect::<Vec<_>>()
            .join(", ");
        c.push_str(&format!("static int64_t {}({});\n", cname(&f.name), args));
    }
    for f in &pr.functions {
        let args = f
            .params
            .iter()
            .map(|n| format!("int64_t {}", cname(n)))
            .collect::<Vec<_>>()
            .join(", ");
        c.push_str(&format!("static int64_t {}({}) {{\n", cname(&f.name), args));
        for s in &f.body {
            c.push_str(&cs(s, 2));
        }
        if !ends_return(&f.body) {
            c.push_str("  return 0;\n");
        }
        c.push_str("}\n");
    }
    c.push_str("int main(int argc, char **argv) {\n  bz_argc = argc; bz_argv = argv;\n");
    for s in &pr.body {
        if !matches!(
            s,
            Stmt::ByteArray(_, _) | Stmt::Let(_, Expr::Number(_) | Expr::Bool(_))
        ) {
            c.push_str(&cs(s, 2));
        }
    }
    c.push_str("  return 0;\n}\n");
    Ok(c)
}

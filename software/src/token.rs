//vocabulary



#[derive(Debug, Clone, PartialEq)]
pub enum Token {
    // J++ Custom Keywords
    Manifest,    // "manifest"
    GrindUntil,  // "grind_until"
    Yeet,        // "yeet"

    // Identifiers and Literals
    Ident(String),
    Num(u8),

    // Operators and Symbols
    Assign,      // "="
    Plus,        // "+"
    Minus,       // "-"
    LessThan,    // "<"
    Equal,       // "=="
    
    // Delimiters
    OpenParen,   // "("
    CloseParen,  // ")"
    OpenBrace,   // "{"
    CloseBrace,  // "}"
    OpenBracket, // "["
    CloseBracket,// "]"
    Semi,        // ";"
}
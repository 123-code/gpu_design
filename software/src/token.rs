//vocabulary



#[derive(Debug, Clone, PartialEq)]
pub enum Token {
    
    Manifest,    
    GrindUntil,  
    Yeet,
    CrunchPush,
    CrunchFire,
    // FC-MAC classifier coprocessor + base-pointer streaming
    FcReset,     // fc_reset      -> FRST
    FcMac,       // fc_mac a, b   -> FMAC
    FcFinalize,  // fc_finalize   -> FARG
    FcBest,      // fc_best x     -> FBEST
    Advance,     // advance [n]   -> ADDB #n (default 1)
    Wbase,       // wbase n       -> WBASE #n
    If,          // if (cond) { } -> CMP + branch + SYNC
    Ident(String),
    Num(u16),
    Assign,      
    Plus,        
    Minus,       
    Star,        // *
    ShiftRight,  // >>
    ShiftLeft,   // <<
    LessThan,    
    Equal,       
    OpenParen,   
    CloseParen,  
    OpenBrace,   
    CloseBrace,  
    OpenBracket,
    CloseBracket,
    Comma,
    Semi,
}
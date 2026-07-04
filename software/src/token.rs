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
    Advance,     // advance       -> ADDB #1
    Ident(String),
    Num(u8), 
    Assign,      
    Plus,        
    Minus,       
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
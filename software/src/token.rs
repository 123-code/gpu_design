//vocabulary



#[derive(Debug, Clone, PartialEq)]
pub enum Token {
    
    Manifest,    
    GrindUntil,  
    Yeet,
    CrunchPush,
    CrunchFire,        
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
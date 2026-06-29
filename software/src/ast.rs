
//file serves as a blueprint for the compilet to know how to structure the abstract syntax tree


/// Represents a piece of code that evaluates to a value
#[derive(Debug, Clone, PartialEq)]
pub enum Expr {
    Number(u8),               
    Variable(String),         
    MemoryAccess(Box<Expr>),  
    BinaryOp {
        left: Box<Expr>,
        op: Op,
        right: Box<Expr>,
    },
}

//"used inside a binaryop, to connect two expressions, allows 4 operations"
#[derive(Debug, Clone, Copy, PartialEq)]
pub enum Op {
    Add,      
    Sub,      
    LessThan, 
    Equal,    
}
 
/// 
#[derive(Debug, Clone, PartialEq)]
pub enum Stmt {
    JoseIgnacioVariable { name: String, value: Expr }, // reserve a register and initialize a variable
    JoseIgnacioAssign { name: String, value: Expr },   // overwrite an existing register
    JoseIgnacioLoop {                            // spin up a loop state machine
        condition: Expr,
        body: Vec<Stmt>,
    },
    JoseIgnacioYeet(Expr),                             // send data to UART (address 63)
}
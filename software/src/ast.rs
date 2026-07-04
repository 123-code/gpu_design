
//file serves as a blueprint for the compilet to know how to structure the abstract syntax tree


/// Represents a piece of code that evaluates to a value
#[derive(Debug, Clone, PartialEq)]
pub enum Expr {
    Number(u8),
    Variable(String),
    MemoryAccess(Box<Expr>),
    ThreadId(IdentityReg),    // tid / bid / bdim -> read-only SIMT identity register
    BinaryOp {
        left: Box<Expr>,
        op: Op,
        right: Box<Expr>,
    },
}

// The three read-only per-lane identity registers (see decoder.sv / TID,BID,BDIM).
#[derive(Debug, Clone, Copy, PartialEq)]
pub enum IdentityReg {
    Tid,  // threadIdx — this lane's index within the warp
    Bid,  // blockIdx  — this core's block id
    Bdim, // blockDim  — threads per block
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
    JoseIgnacioStore { address: Expr, value: Expr }, // mem[address] = value;
    JoseIgnacioLoop { condition: Expr, body: Vec<Stmt> },
    JoseIgnacioYeet(Expr), 
    CrunchPush(Expr),   
    CrunchFire{dest: String},                        
}
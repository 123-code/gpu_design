
//file serves as a blueprint for the compilet to know how to structure the abstract syntax tree


/// Represents a piece of code that evaluates to a value
#[derive(Debug, Clone, PartialEq)]
pub enum Expr {
    Number(u16),
    Variable(String),
    MemoryAccess(Box<Expr>),
    ThreadId(IdentityReg),    // tid / bid / bdim -> read-only SIMT identity register
    Max(Box<Expr>, Box<Expr>), // max(a, b)
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
    Mul,      // low 16 bits
    Shr,      // >>
    Shl,      // <<
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
    CrunchPush { pixel: Expr, weight: Option<Expr> }, // push (pixel, weight) pair into the MAC buffer; weight defaults to R0
    CrunchFire { dest: String, byte: u8 }, // byte 0..3 of the 32-bit MAC result
    JoseIgnacioIf { condition: Expr, body: Vec<Stmt> },
    // FC-MAC classifier coprocessor + base-pointer streaming
    FcReset,                                  // fc_reset      -> FRST
    FcMac { feature: Expr, weight: Expr },    // fc_mac a, b   -> FMAC
    FcFinalize,                               // fc_finalize   -> FARG
    FcBest { dest: String },                  // fc_best x     -> FBEST
    Advance(u16),                             // advance [n]   -> ADDB #n
    Wbase(u16),                               // wbase n       -> WBASE #n
}
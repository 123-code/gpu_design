// software/src/codegen.rs
// Walks the AST and emits tiny-gpu assembly text (one String per line), which
// the assembler (src/main.rs) turns into .hex.
//
// Register plan: R0..R5 hold variables, R6/R7 are scratch for expression
// temporaries (reset at the start of every statement). A computed operand held
// in a scratch register is dead once used, so each operation writes its result
// back into one of its scratch operands; an assignment then retargets the last
// instruction at the variable instead of copying. Comparisons set the N/Z/P
// flags via CMP and only appear in loop/if conditions; arithmetic (+ - * << >>)
// and max() appear in value expressions.
//
// Divergence: all threads of a warp share one PC, so a branch whose threads
// disagree makes the scheduler run one side, then SYNC pops back to run the
// other (scheduler.sv). `if` and `max` are laid out so the side that jumps
// lands directly on a SYNC:
//
//     CMP ; BR<exit> Lskip ; <body> ; Lskip: SYNC
//
// Threads that disagree -> the jumping ones hit SYNC, which pops and runs the
// body on the others; the body falls into the same SYNC, which (stack empty)
// restores every thread. Threads that agree -> SYNC with an empty stack is a
// no-op. A SYNC nested inside another if's body would restore threads the
// outer if masked off, so if/max are rejected there. Loops emit no SYNC and
// still assume every thread takes the same path.

use crate::ast::{Stmt, Expr, Op, IdentityReg};
use std::collections::HashMap;

const MAX_VAR_REG: u8 = 5; // R0..R5 for variables
const SCRATCH_BASE: u8 = 6; // R6, R7 for temporaries
const UART_TX_ADDR: u8 = 63; // STR to offset 63 -> UART TX (lsu.sv)
const IMM_MAX: u16 = 63;     // 6-bit immediate field

pub struct Codegen {
    ast: Vec<Stmt>,
    pub assembly: Vec<String>,
    variables: HashMap<String, u8>,
    next_var_reg: u8,
    scratch_used: u8, // bit 0 = R6 in use, bit 1 = R7 in use
    label_counter: usize,
    if_depth: usize,
}

impl Codegen {
    pub fn new(ast: Vec<Stmt>) -> Self {
        Codegen {
            ast,
            assembly: Vec::new(),
            variables: HashMap::new(),
            next_var_reg: 0,
            scratch_used: 0,
            label_counter: 1,
            if_depth: 0,
        }
    }

    pub fn generate(&mut self) -> Result<(), String> {
        let tree = self.ast.clone(); // clone to iterate while emitting into self
        for stmt in &tree {
            self.gen_statement(stmt)?;
        }
        self.emit("RET");
        // The UART->DMA program loader silently drops the final word, so emit a
        // second sacrificial RET: the real one above always survives the drop.
        self.emit("RET");
        Ok(())
    }

    // --- helpers ---

    fn emit(&mut self, line: impl Into<String>) {
        self.assembly.push(line.into());
    }

    // One MOV when the constant fits the 6-bit immediate, else the 3-word LDI.
    fn load_const(&mut self, reg: u8, n: u16) {
        if n <= IMM_MAX {
            self.emit(format!("MOV R{}, #{}", reg, n));
        } else {
            self.emit(format!("LDI R{}, #{}", reg, n));
        }
    }

    // ADDB / WBASE take a 6-bit immediate, so larger moves are split into steps of 63.
    fn emit_base_move(&mut self, mnemonic: &str, mut n: u16) {
        while n > IMM_MAX {
            self.emit(format!("{} #{}", mnemonic, IMM_MAX));
            n -= IMM_MAX;
        }
        if n > 0 {
            self.emit(format!("{} #{}", mnemonic, n));
        }
    }

    fn next_label(&mut self, prefix: &str) -> String {
        let k = self.label_counter;
        self.label_counter += 1;
        format!("{}{}", prefix, k)
    }

    // If the last line wrote scratch register `from` as its destination, make it
    // write `to` instead (the scratch value was only needed for the copy).
    fn retarget_last(&mut self, from: u8, to: u8) -> bool {
        const WRITES_RD: [&str; 12] = ["MOV", "LDI", "ADD", "ADDI", "SUB", "MUL", "SHR", "SHL", "LDR", "TID", "BID", "BDIM"];
        if from < SCRATCH_BASE {
            return false;
        }
        let Some(last) = self.assembly.last_mut() else { return false };
        let Some((mnem, rest)) = last.split_once(' ') else { return false };
        let rd = format!("R{}", from);
        let rd_is_from = rest.split(',').next().map(str::trim) == Some(rd.as_str());
        if !WRITES_RD.contains(&mnem) || !rd_is_from {
            return false;
        }
        *last = format!("{} R{}{}", mnem, to, &rest[rd.len()..]);
        true
    }

    // Result register for an operation: reuse a computed (scratch) operand, since
    // it is dead after this instruction, else take a fresh scratch register.
    fn result_reg(&mut self, lr: u8, rr: u8) -> Result<u8, String> {
        if lr >= SCRATCH_BASE {
            if rr != lr {
                self.release(rr);
            }
            Ok(lr)
        } else if rr >= SCRATCH_BASE {
            Ok(rr)
        } else {
            self.scratch()
        }
    }

    // Grab a free scratch register (R6 or R7). All are freed at each statement.
    fn scratch(&mut self) -> Result<u8, String> {
        for bit in 0..2 {
            if self.scratch_used & (1 << bit) == 0 {
                self.scratch_used |= 1 << bit;
                return Ok(SCRATCH_BASE + bit);
            }
        }
        Err("expression too complex (out of scratch registers R6/R7)".into())
    }

    // A scratch operand that has been consumed can be handed out again.
    fn release(&mut self, r: u8) {
        if r >= SCRATCH_BASE {
            self.scratch_used &= !(1 << (r - SCRATCH_BASE));
        }
    }

    fn var_reg(&self, name: &str) -> Result<u8, String> {
        self.variables
            .get(name)
            .copied()
            .ok_or_else(|| format!("use of undeclared variable '{}'", name))
    }



    fn gen_statement(&mut self, stmt: &Stmt) -> Result<(), String> {
        self.scratch_used = 0;
        match stmt {
            Stmt::JoseIgnacioVariable { name, value } => self.gen_manifest(name, value),
            Stmt::JoseIgnacioAssign { name, value } => self.gen_assign(name, value),
            Stmt::JoseIgnacioStore { address, value } => self.gen_store(address, value),
            Stmt::JoseIgnacioLoop { condition, body } => self.gen_grind_until(condition, body),
            Stmt::JoseIgnacioIf { condition, body } => self.gen_if(condition, body),
            Stmt::JoseIgnacioYeet(value) => self.gen_yeet(value),
            Stmt::CrunchPush { pixel, weight } => self.gen_crunch_push(pixel, weight),
            Stmt::FcReset    => { self.emit("FRST"); Ok(()) }
            Stmt::FcFinalize => { self.emit("FARG"); Ok(()) }
            Stmt::Advance(n) => { self.emit_base_move("ADDB", *n); Ok(()) }
            Stmt::Wbase(n)   => { self.emit_base_move("WBASE", *n); Ok(()) }
            Stmt::FcMac { feature, weight } => {
                let rf = self.gen_expr(feature)?;
                let rw = self.gen_expr(weight)?;
                self.emit(format!("FMAC R{}, R{}", rf, rw));
                Ok(())
            }
            Stmt::FcBest { dest } => {
                let rd = self.var_reg(dest)?;
                self.emit(format!("FBEST R{}", rd));
                Ok(())
            }       
            Stmt::CrunchFire { dest, byte } => self.gen_crunch_fire(dest, *byte),
        }
    }

   
    fn gen_manifest(&mut self, name: &str, value: &Expr) -> Result<(), String> {
        if self.next_var_reg > MAX_VAR_REG {
            return Err("out of variable registers (only R0..R5 available)".into());
        }
        let reg = self.next_var_reg;
        self.next_var_reg += 1;
        self.variables.insert(name.to_string(), reg);
        self.emit(format!("// {} -> R{}", name, reg));
        self.store_into(reg, value)
    }

    // s = <expr>;
    fn gen_assign(&mut self, name: &str, value: &Expr) -> Result<(), String> {
        let dest = self.var_reg(name)?;
        self.store_into(dest, value)
    }

    // Emit code so that register `dest` ends up holding `value`.
    fn store_into(&mut self, dest: u8, value: &Expr) -> Result<(), String> {
        match value {
            // Common case: a literal goes straight in with one MOV.
            Expr::Number(n) => {
                self.load_const(dest, *n);
                Ok(())
            }
            _ => {
                let r = self.gen_expr(value)?;
                if r != dest && !self.retarget_last(r, dest) {
                    self.emit(format!("ADDI R{}, R{}, #0", dest, r));
                }
                Ok(())
            }
        }
    }

    // yeet <expr>;  -> evaluate, then STR to the UART TX address.
    fn gen_yeet(&mut self, value: &Expr) -> Result<(), String> {
        let r = self.gen_expr(value)?;
        let addr = self.scratch()?;
        self.emit(format!("MOV R{}, #{}", addr, UART_TX_ADDR));
        self.emit(format!("STR R{}, [R{}]", r, addr));
        Ok(())
    }

    // grind_until (<cond>) { body }  -> loop WHILE cond is true.
    fn gen_grind_until(&mut self, condition: &Expr, body: &[Stmt]) -> Result<(), String> {
        let k = self.label_counter;
        self.label_counter += 1;
        let l_cond = format!("Lcond{}", k);
        let l_end = format!("Lend{}", k);

        self.emit(format!("{}:", l_cond));
        let exit_branch = self.gen_condition(condition)?; // emits CMP, returns exit mnemonic
        self.emit(format!("{} {}", exit_branch, l_end));

        for stmt in body {
            self.gen_statement(stmt)?;
        }
        self.scratch_used = 0; // back-edge is its own "statement"
        self.emit(format!("BR {}", l_cond));
        self.emit(format!("{}:", l_end));
        Ok(())
    }

    // if (<cond>) { body }  -> CMP ; BR<exit> Lskip ; body ; Lskip: SYNC
    // (layout explained at the top of the file)
    fn gen_if(&mut self, condition: &Expr, body: &[Stmt]) -> Result<(), String> {
        if self.if_depth > 0 {
            return Err("'if' inside another 'if' is not supported (the inner SYNC would wake threads the outer if masked)".into());
        }
        let l_skip = self.next_label("Lskip");
        let exit_branch = self.gen_condition(condition)?;
        self.emit(format!("{} {}", exit_branch, l_skip));

        self.if_depth += 1;
        for stmt in body {
            self.gen_statement(stmt)?;
        }
        self.if_depth -= 1;

        self.emit(format!("{}:", l_skip));
        self.emit("SYNC");
        Ok(())
    }

    // Evaluate a comparison into the N/Z/P flags via CMP. Returns the branch
    // mnemonic that LEAVES the loop (the complement of the condition).
    fn gen_condition(&mut self, cond: &Expr) -> Result<&'static str, String> {
        let (left, op, right) = match cond {
            Expr::BinaryOp { left, op, right } => (left, *op, right),
            _ => return Err("loop condition must be a comparison (< or ==)".into()),
        };
        let lr = self.gen_expr(left)?;
        let rr = self.gen_expr(right)?;
        self.emit(format!("CMP R{}, R{}", lr, rr));
        match op {
            // CMP Rl,Rr sets N=(l<r), Z=(l==r), P=(l>r).
            Op::LessThan => Ok("BRzp"), // exit when NOT(l<r): l>=r
            Op::Equal => Ok("BRnp"),    // exit when NOT(l==r): l<r or l>r
            _ => Err("loop condition operator must be < or ==".into()),
        }
    }

    // --- expressions: returns the register holding the value ---
    // Variables return their home register (no copy, never clobbered). Numbers
    // and computed results land in a scratch register.
    fn gen_expr(&mut self, e: &Expr) -> Result<u8, String> {
        match e {
            Expr::Number(n) => {
                let r = self.scratch()?;
                self.load_const(r, *n);
                Ok(r)
            }
            Expr::Variable(name) => self.var_reg(name),
            Expr::ThreadId(kind) => {
                let r = self.scratch()?;
                let mnem = match kind {
                    IdentityReg::Tid => "TID",
                    IdentityReg::Bid => "BID",
                    IdentityReg::Bdim => "BDIM",
                };
                self.emit(format!("{} R{}", mnem, r));
                Ok(r)
            }
            Expr::BinaryOp { left, op, right } => {
                let lr = self.gen_expr(left)?;
                // ADD with an immediate right operand -> ADDI, no scratch for the constant.
                if let (Op::Add, Expr::Number(n @ 0..=IMM_MAX)) = (op, right.as_ref()) {
                    let d = if lr >= SCRATCH_BASE { lr } else { self.scratch()? };
                    self.emit(format!("ADDI R{}, R{}, #{}", d, lr, n));
                    return Ok(d);
                }
                let rr = self.gen_expr(right)?;
                let d = self.result_reg(lr, rr)?;
                let mnem = match op {
                    Op::Add => "ADD",
                    Op::Sub => "SUB",
                    Op::Mul => "MUL",
                    Op::Shr => "SHR",
                    Op::Shl => "SHL",
                    Op::LessThan | Op::Equal => {
                        return Err("comparison cannot be used as a value (only in conditions)".into());
                    }
                };
                self.emit(format!("{} R{}, R{}, R{}", mnem, d, lr, rr));
                Ok(d)
            }
            // max(a, b) -> ADDI d,a ; CMP b,a ; BRn Lmax ; ADDI d,b ; Lmax: SYNC
            Expr::Max(a, b) => {
                if self.if_depth > 0 {
                    return Err("max() inside an 'if' is not supported (its SYNC would wake threads the if masked)".into());
                }
                let mut ra = self.gen_expr(a)?;
                let mut rb = self.gen_expr(b)?;
                // The result may overwrite `a` (it is copied first) but never `b`
                // (still needed by the CMP), and never a live variable register.
                if ra < SCRATCH_BASE && rb >= SCRATCH_BASE {
                    std::mem::swap(&mut ra, &mut rb); // max is symmetric
                }
                let d = if ra >= SCRATCH_BASE { ra } else { self.scratch()? };
                let l_max = self.next_label("Lmax");
                if d != ra {
                    self.emit(format!("ADDI R{}, R{}, #0", d, ra));
                }
                self.emit(format!("CMP R{}, R{}", rb, d));
                self.emit(format!("BRn {}", l_max)); // b < a: keep a
                self.emit(format!("ADDI R{}, R{}, #0", d, rb));
                self.emit(format!("{}:", l_max));
                self.emit("SYNC");
                if rb != d {
                    self.release(rb);
                }
                Ok(d)
            }
            Expr::MemoryAccess(index_expr) => {
    // Compute the index. If it landed in a scratch register, the index is dead
    // after the load, so load in place and reuse it (1 scratch instead of 2).
    // If it's a live variable register, load into a fresh scratch so we don't
    // clobber the variable.
    let r_index = self.gen_expr(index_expr)?;
    let r_dest = if r_index >= SCRATCH_BASE { r_index } else { self.scratch()? };
    self.emit(format!("LDR R{}, [R{}]", r_dest, r_index));
    Ok(r_dest)
}
        }
    }

 
// crunch_push <expr>; -> evaluates expression to a scratch register, emits MACL
    fn gen_crunch_push(&mut self, pixel: &Expr, weight: &Option<Expr>) -> Result<(), String> {
        let r_pix = self.gen_expr(pixel)?;
        match weight {
            Some(w) => {
                let r_w = self.gen_expr(w)?;
                self.emit(format!("MACL R{}, R{}", r_pix, r_w));
            }
            None => self.emit(format!("MACL R{}", r_pix)), // weight defaults to R0
        }
        Ok(())
    }

    // crunch_fire <variable> [, byte]; -> MAC writes byte 0..3 of the 32-bit result into the variable
    fn gen_crunch_fire(&mut self, dest: &str, byte: u8) -> Result<(), String> {
        let r_dest = self.var_reg(dest)?;
        self.emit(format!("MAC R{}, #{}", r_dest, byte));
        Ok(())
    }
  

    fn gen_store(&mut self, address: &Expr, value: &Expr) -> Result<(), String> {
        let r_addr = self.gen_expr(address)?;
        let r_data = self.gen_expr(value)?;
        self.emit(format!("STR R{}, [R{}]", r_data, r_addr));
        
        Ok(())
    }
}

// software/src/codegen.rs
// Walks the AST and emits tiny-gpu assembly text (one String per line), which
// the assembler (src/main.rs) turns into .hex.
//
// Register plan: R0..R5 hold variables, R6/R7 are scratch for expression
// temporaries (reset at the start of every statement). Comparisons set the
// N/Z/P flags via CMP and only appear in loop conditions; arithmetic (+ - *)
// appears in value expressions.

use crate::ast::{Stmt, Expr, Op};
use std::collections::HashMap;

const MAX_VAR_REG: u8 = 5; // R0..R5 for variables
const SCRATCH_BASE: u8 = 6; // R6, R7 for temporaries
const UART_TX_ADDR: u8 = 63; // STR to offset 63 -> UART TX (lsu.sv)

pub struct Codegen {
    ast: Vec<Stmt>,
    pub assembly: Vec<String>,
    variables: HashMap<String, u8>,
    next_var_reg: u8,
    next_scratch: u8,
    label_counter: usize,
}

impl Codegen {
    pub fn new(ast: Vec<Stmt>) -> Self {
        Codegen {
            ast,
            assembly: Vec::new(),
            variables: HashMap::new(),
            next_var_reg: 0,
            next_scratch: SCRATCH_BASE,
            label_counter: 1,
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

    // Grab the next free scratch register (R6 then R7). Reset per statement.
    fn scratch(&mut self) -> Result<u8, String> {
        if self.next_scratch > 7 {
            return Err("expression too complex (out of scratch registers R6/R7)".into());
        }
        let r = self.next_scratch;
        self.next_scratch += 1;
        Ok(r)
    }

    fn var_reg(&self, name: &str) -> Result<u8, String> {
        self.variables
            .get(name)
            .copied()
            .ok_or_else(|| format!("use of undeclared variable '{}'", name))
    }

    // --- statements ---

    fn gen_statement(&mut self, stmt: &Stmt) -> Result<(), String> {
        self.next_scratch = SCRATCH_BASE; // each statement starts with fresh scratch
        match stmt {
            Stmt::JoseIgnacioVariable { name, value } => self.gen_manifest(name, value),
            Stmt::JoseIgnacioAssign { name, value } => self.gen_assign(name, value),
            Stmt::JoseIgnacioLoop { condition, body } => self.gen_grind_until(condition, body),
            Stmt::JoseIgnacioYeet(value) => self.gen_yeet(value),
        }
    }

    // manifest s = <expr>;  -> reserve a register, then assign into it.
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
                self.emit(format!("MOV R{}, #{}", dest, n));
                Ok(())
            }
            _ => {
                let r = self.gen_expr(value)?;
                if r != dest {
                    // ponytail: reg->reg copy via ADDI #0; could fold dest into the
                    // final op of gen_expr to drop this, if instruction count matters.
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
        self.next_scratch = SCRATCH_BASE; // back-edge is its own "statement"
        self.emit(format!("BR {}", l_cond));
        self.emit(format!("{}:", l_end));
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
                self.emit(format!("MOV R{}, #{}", r, n));
                Ok(r)
            }
            Expr::Variable(name) => self.var_reg(name),
            Expr::BinaryOp { left, op, right } => {
                let lr = self.gen_expr(left)?;
                // ADD with an immediate right operand -> ADDI, no scratch for the constant.
                if let (Op::Add, Expr::Number(n)) = (op, right.as_ref()) {
                    let d = self.scratch()?;
                    self.emit(format!("ADDI R{}, R{}, #{}", d, lr, n));
                    return Ok(d);
                }
                let rr = self.gen_expr(right)?;
                let d = self.scratch()?;
                let mnem = match op {
                    Op::Add => "ADD",
                    Op::Sub => "SUB",
                    Op::LessThan | Op::Equal => {
                        return Err("comparison cannot be used as a value (only in conditions)".into());
                    }
                };
                self.emit(format!("{} R{}, R{}, R{}", mnem, d, lr, rr));
                Ok(d)
            }
            Expr::MemoryAccess(_) => Err("mem[] not supported yet".into()),
        }
    }
}

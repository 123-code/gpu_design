//! J++ compiler library: source text → tokens → AST → (later) tiny-gpu asm.
//! The assembler that turns that asm into .hex lives in the default binary
//! (`src/main.rs`); the J++ driver is `src/bin/jpp.rs`.

pub mod token;
pub mod lexer;
pub mod ast;
pub mod parser;
pub mod codegen;

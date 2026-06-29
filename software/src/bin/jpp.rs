// J++ compiler driver: source file -> tokens -> AST -> tiny-gpu .asm
// Usage: cargo run --bin jpp -- <input.jpp> [output.asm]
//        (defaults: program.jpp -> program.asm)
use software::lexer::Lexer;
use software::parser::Parser;
use software::codegen::Codegen;
use std::fs;

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let in_path = args.get(1).map(String::as_str).unwrap_or("program.jpp");
    let out_path = args.get(2).map(String::as_str).unwrap_or("program.asm");

    let source_code = match fs::read_to_string(in_path) {
        Ok(s) => s,
        Err(e) => return eprintln!("Cannot read {}: {}", in_path, e),
    };

    let mut lexer = Lexer::new(&source_code);
    let tokens = match lexer.tokenize() {
        Ok(t) => t,
        Err(e) => return eprintln!("Lexer error: {}", e),
    };

    let mut parser = Parser::new(tokens);
    let ast = match parser.parse_program() {
        Ok(a) => a,
        Err(e) => return eprintln!("Parser error: {}", e),
    };

    let mut codegen = Codegen::new(ast);
    if let Err(e) = codegen.generate() {
        return eprintln!("Codegen error: {}", e);
    }

    let asm = codegen.assembly.join("\n") + "\n";
    println!("=== {} -> tiny-gpu asm ===\n{}", in_path, asm);
    if let Err(e) = fs::write(out_path, &asm) {
        return eprintln!("Failed to write {}: {}", out_path, e);
    }
    println!("Wrote {}", out_path);
}

// Compiler-side checks for the J++ features added for full on-chip models.
// Hardware behaviour of if / max / big constants is checked separately by
// test/tb_jpp_features.sv (make sim-jpp-features).
use software::codegen::Codegen;
use software::lexer::Lexer;
use software::parser::Parser;

fn compile(src: &str) -> Result<Vec<String>, String> {
    let tokens = Lexer::new(src).tokenize()?;
    let ast = Parser::new(tokens).parse_program()?;
    let mut cg = Codegen::new(ast);
    cg.generate()?;
    Ok(cg.assembly)
}

fn has(asm: &[String], line: &str) -> bool {
    asm.iter().any(|l| l == line)
}

#[test]
fn constants_above_63_use_ldi() {
    let asm = compile("manifest x = 100; x = x + 100; x = x + 5;").unwrap();
    assert!(has(&asm, "LDI R0, #100"));
    assert!(!asm.iter().any(|l| l.contains("#100") && l.starts_with("ADDI")));
    assert!(has(&asm, "ADDI R0, R0, #5")); // small constants keep the 1-word ADDI, written straight into x
    assert!(has(&compile("manifest p = 1629;").unwrap(), "LDI R0, #1629")); // full 16-bit range
}

#[test]
fn crunch_fire_selects_a_byte() {
    let asm = compile("manifest s = 0; crunch_fire s; crunch_fire s, 2;").unwrap();
    assert!(has(&asm, "MAC R0, #0"));
    assert!(has(&asm, "MAC R0, #2"));
    assert!(compile("manifest s = 0; crunch_fire s, 4;").is_err());
}

#[test]
fn base_moves_split_into_steps_of_63() {
    let asm = compile("advance; advance 5; wbase 130;").unwrap();
    assert!(has(&asm, "ADDB #1"));
    assert!(has(&asm, "ADDB #5"));
    let wb: Vec<_> = asm.iter().filter(|l| l.starts_with("WBASE")).cloned().collect();
    assert_eq!(wb, ["WBASE #63", "WBASE #63", "WBASE #4"]);
}

#[test]
fn if_and_max_end_on_sync() {
    let asm = compile("manifest a = tid; manifest m = max(a, 2); if (a < 2) { m = 9; }").unwrap();
    assert_eq!(asm.iter().filter(|l| *l == "SYNC").count(), 2);
    // the label each branch jumps to is immediately followed by SYNC
    for (i, l) in asm.iter().enumerate() {
        if l.ends_with(':') {
            assert_eq!(asm[i + 1], "SYNC", "label {} not followed by SYNC", l);
        }
    }
}

#[test]
fn if_or_max_nested_in_if_is_rejected() {
    assert!(compile("manifest a = 1; if (a < 2) { if (a < 1) { a = 0; } }").is_err());
    assert!(compile("manifest a = 1; if (a < 2) { a = max(a, 3); }").is_err());
    assert!(compile("manifest a = 1; if (a < 2) { grind_until (a < 5) { a = a + 1; } }").is_ok());
}

#[test]
fn multiply_shift_and_parentheses() {
    // * binds tighter than +, which binds tighter than << and >>
    let asm = compile("manifest a = 3; manifest b = 4; manifest c = 0; c = a + b * 2; c = (a + b) >> 1; c = a << b;").unwrap();
    assert!(has(&asm, "MUL R6, R1, R6"));       // b * 2, into the scratch holding 2
    assert!(has(&asm, "ADD R2, R0, R6"));       // a + (b*2), written straight into c
    assert!(has(&asm, "ADD R6, R0, R1"));       // (a + b)
    assert!(has(&asm, "SHR R2, R6, R7"));       // ... >> 1
    assert!(has(&asm, "SHL R2, R0, R1"));
}

#[test]
fn expressions_reuse_scratch_registers() {
    // three operations in one statement would need 3 fresh temporaries without reuse
    assert!(compile("manifest c = 0; manifest g = 0; g = g + mem[c + 56] * 127;").is_ok());
    assert!(compile("manifest a = 0; manifest b = 0; manifest c = 0; a = (a >> 8) + (b >> 8) + (c >> 8);").is_ok());
}

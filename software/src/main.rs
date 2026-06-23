use std::collections::HashMap;
use std::fs::File;
use std::io::{self, BufRead, BufReader, Write};

// ============================================================================
// tiny-gpu assembler (two-pass).
//
// 16-bit encoding:  [15:12] opcode  [11:9] rd  [8:6] rs  [5:0] imm / [2:0] rt
//
// Pass 1 assigns an address to every emitted instruction word and records
// labels (`name:`). Pass 2 encodes each line, resolving label references in
// BRn. Pseudo-ops (MAX) expand to several words. Comments start with // or ;.
// ============================================================================

fn reg(s: &str) -> u16 {
    let n = s
        .trim()
        .trim_matches(|c| c == '[' || c == ']')
        .trim_start_matches('R')
        .parse()
        .unwrap_or(0);
    // Instruction register fields are 3-bit: only R0..R7 are addressable.
    // (R13..R15 are SIMT identity regs, unreachable by the encoding.)
    if n > 7 {
        eprintln!("ERROR: R{} is not addressable — instructions can only use R0..R7", n);
        std::process::exit(1);
    }
    n
}

fn imm(s: &str) -> u16 {
    let t = s.trim().trim_start_matches('#');
    if let Some(h) = t.strip_prefix("0x") {
        u16::from_str_radix(h, 16).unwrap_or(0)
    } else {
        t.parse().unwrap_or(0)
    }
}

// Strip comments (// or ;) and surrounding whitespace.
fn clean(line: &str) -> String {
    let no_slash = line.split("//").next().unwrap_or("");
    let no_semi = no_slash.split(';').next().unwrap_or("");
    no_semi.trim().to_string()
}

// Split a cleaned line into an optional label and the remaining tokens.
fn split_label(line: &str) -> (Option<String>, Vec<String>) {
    let mut label = None;
    let mut rest = line.to_string();
    if let Some(idx) = line.find(':') {
        label = Some(line[..idx].trim().to_string());
        rest = line[idx + 1..].trim().to_string();
    }
    let toks: Vec<String> = rest
        .replace(',', " ")
        .split_whitespace()
        .map(|s| s.to_string())
        .collect();
    (label, toks)
}

// How many machine words does this instruction expand to?
fn word_count(mnemonic: &str) -> u16 {
    match mnemonic {
        "MAX" => 4, // pseudo-op: ADDI / CMP / BRn / ADDI
        _ => 1,
    }
}

// Field assembly helper.
fn w(op: u16, rd: u16, rs: u16, low6: u16) -> u16 {
    (op << 12) | ((rd & 7) << 9) | ((rs & 7) << 6) | (low6 & 0x3f)
}

// Encode one source instruction into its machine word(s). `pc` is this line's
// address (needed for the MAX pseudo-op's internal branch); `labels` resolves
// BRn targets.
fn encode(toks: &[String], pc: u16, labels: &HashMap<String, u16>) -> Vec<u16> {
    let m = toks[0].as_str();
    let target = |s: &str| -> u16 {
        if let Some(&a) = labels.get(s) {
            a
        } else {
            imm(s)
        }
    };
    match m {
        // ADD Rd,Rs,Rt  (0001)  |  ADD Rd,Rs,#imm -> ADDI (0101)
        "ADD" => {
            if toks[3].starts_with('#') {
                vec![w(0b0101, reg(&toks[1]), reg(&toks[2]), imm(&toks[3]))]
            } else {
                vec![w(0b0001, reg(&toks[1]), reg(&toks[2]), reg(&toks[3]))]
            }
        }
        "ADDI" => vec![w(0b0101, reg(&toks[1]), reg(&toks[2]), imm(&toks[3]))],
        "MUL" => vec![w(0b1010, reg(&toks[1]), reg(&toks[2]), reg(&toks[3]))],
        "SHR" => vec![w(0b1100, reg(&toks[1]), reg(&toks[2]), reg(&toks[3]))],
        "SHL" => vec![w(0b1101, reg(&toks[1]), reg(&toks[2]), reg(&toks[3]))],
        "SUB" => vec![w(0b1110, reg(&toks[1]), reg(&toks[2]), reg(&toks[3]))],
        "MOV" => vec![w(0b0010, reg(&toks[1]), 0, imm(&toks[2]))],
        // SIMT identity reads: MOV-variant with rs selecting an identity register.
        //   TID  rd -> rd = threadIdx (R15)   BID rd -> rd = blockIdx (R13)
        //   BDIM rd -> rd = blockDim  (R14)
        "TID" => vec![w(0b0010, reg(&toks[1]), 1, 0)],
        "BID" => vec![w(0b0010, reg(&toks[1]), 2, 0)],
        "BDIM" => vec![w(0b0010, reg(&toks[1]), 3, 0)],
        "CMP" => vec![w(0b0011, 0, reg(&toks[1]), reg(&toks[2]))],
        "LDR" => vec![w(0b0100, reg(&toks[1]), reg(&toks[2]), 0)],
        "MACL" => vec![w(0b0110, 0, reg(&toks[1]), 0)],
        // MAC Rd       -> write byte 0 (LSB) of the 32-bit MAC result into Rd
        // MAC Rd, #n   -> write byte n (0..3) — read the full 32-bit result in 4 ops
        "MAC" => vec![w(0b0111, reg(&toks[1]), 0,
                        toks.get(2).map_or(0, |t| imm(t) & 0b11))],
        // BRn target (8-bit, into [7:0]); condition = N flag in [11:9]
        "BRn" => vec![(0b1000 << 12) | (0b100 << 9) | (target(&toks[1]) & 0xff)],
        "ADDB" => vec![w(0b1001, 0, 0, imm(&toks[1]))],
        // WBASE: advance the write base. ADDB opcode with instruction[11] set
        // (rd field = 0b100) so the decoder routes it to wbase, no new opcode.
        "WBASE" => vec![w(0b1001, 0b100, 0, imm(&toks[1]))],
        // STR Rdata,[Raddr]  ->  addr in [8:6], data in [2:0]
        "STR" => vec![w(0b1011, 0, reg(&toks[2]), reg(&toks[1]) & 7)],
        "RET" => vec![0xF000],
        // SYNC: RET opcode with bit 0 set -> decoder raises decoded_sync, which
        // pops the warp's reconvergence stack (run the other side of a divergent
        // branch). No new opcode needed.
        "SYNC" => vec![0xF001],

        // ---- FC-MAC + argmax coprocessor (opcode 0000, sub-fn in [5:4]) ----
        "FRST" => vec![0x0000],                                   // [5:4]=00 reset engine
        "FMAC" => vec![w(0b0000, 0, reg(&toks[1]), 0b010_000 | (reg(&toks[2]) & 7))], // [5:4]=01
        "FARG" => vec![w(0b0000, 0, 0, 0b100_000)],               // [5:4]=10 finalize digit
        "FBEST" => vec![w(0b0000, reg(&toks[1]), 0, 0b110_000)],  // [5:4]=11 rd <- best_idx

        // ---- MAX Rd,Ra,Rb  (pseudo): Rd = max(Ra,Rb) ----
        // ADDI Rd,Ra,#0 ; CMP Rb,Ra ; BRn skip ; ADDI Rd,Rb,#0 ; skip:
        "MAX" => {
            let (rd, ra, rb) = (reg(&toks[1]), reg(&toks[2]), reg(&toks[3]));
            let skip = pc + 4;
            vec![
                w(0b0101, rd, ra, 0),                       // Rd = Ra + 0
                w(0b0011, 0, rb, ra),                       // CMP Rb,Ra  (N if Rb<Ra)
                (0b1000 << 12) | (0b100 << 9) | (skip & 0xff), // BRn skip (Ra is max)
                w(0b0101, rd, rb, 0),                       // Rd = Rb + 0
            ]
        }

        other => {
            eprintln!("Unknown instruction: {}", other);
            vec![]
        }
    }
}

fn main() -> io::Result<()> {
    let args: Vec<String> = std::env::args().collect();
    let in_path = args.get(1).map(String::as_str).unwrap_or("test_kernel.asm");
    let out_path = args.get(2).map(String::as_str).unwrap_or("kernel.hex");

    let reader = BufReader::new(File::open(in_path)?);
    let raw: Vec<String> = reader.lines().collect::<Result<_, _>>()?;

    // Parse into (label, tokens) per non-empty line.
    let mut parsed: Vec<(Option<String>, Vec<String>)> = Vec::new();
    for line in &raw {
        let c = clean(line);
        if c.is_empty() {
            continue;
        }
        let (label, toks) = split_label(&c);
        // Skip lines that are only a label with no instruction (still record label).
        parsed.push((label, toks));
    }

    // Pass 1: assign addresses + collect labels.
    let mut labels: HashMap<String, u16> = HashMap::new();
    let mut pc: u16 = 0;
    for (label, toks) in &parsed {
        if let Some(l) = label {
            if !l.is_empty() {
                labels.insert(l.clone(), pc);
            }
        }
        if !toks.is_empty() {
            pc += word_count(&toks[0]);
        }
    }

    // Pass 2: encode.
    let mut out = File::create(out_path)?;
    println!("{:<24} | {:<16} | {}", "Assembly", "Binary", "Hex");
    println!("{:-<52}", "");
    let mut pc: u16 = 0;
    for (_label, toks) in &parsed {
        if toks.is_empty() {
            continue;
        }
        let words = encode(toks, pc, &labels);
        for word in words {
            writeln!(out, "{:04X}", word)?;
            println!(
                "{:<24} | {:016b} | {:04X}",
                toks.join(" "),
                word,
                word
            );
            pc += 1;
        }
    }
    println!("{:-<52}", "");
    println!("Wrote {} ({} words) to {}", in_path, pc, out_path);
    Ok(())
}

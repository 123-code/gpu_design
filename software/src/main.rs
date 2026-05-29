use std::fs::File;
use std::io::{self, BufRead, BufReader, Write};

/// Helper: Converts a string like "R3" into a 3-bit binary string "011"
fn reg_to_bin(reg_str: &str) -> String {
    let num: u8 = reg_str.replace("R", "").parse().unwrap_or(0);
    format!("{:03b}", num)
}

/// Helper: Converts a string like "#5" or "4" into an N-bit binary string
fn imm_to_bin(imm_str: &str, bits: usize) -> String {
    let num: u8 = imm_str.replace("#", "").parse().unwrap_or(0);
    format!("{:0width$b}", num, width = bits)
}

/// The core compilation engine
fn assemble_line(line: &str) -> Option<String> {
    // Clean the line: remove comments and trim whitespace
    let clean_line = line.split("//").next().unwrap_or("").trim();
    if clean_line.is_empty() {
        return None;
    }

    let replaced = clean_line.replace(",", "");
    let parts: Vec<&str> = replaced.split_whitespace().collect();
    let instruction = parts[0];

    // Build the 16-bit binary string
    let mut binary_out = String::new();

    match instruction {
        // ADD (0001) with a register src2, or ADDI (0101) with an immediate src2.
        // These MUST be distinct opcodes: the hardware has no other way to know
        // whether [5:0] is a register index or an immediate value.
        "ADD" => {
            let dest = reg_to_bin(parts[1]);
            let src1 = reg_to_bin(parts[2]);

            // Check if the 3rd argument is an immediate number (#1) or a register (R4)
            let (opcode, src2_imm) = if parts[3].starts_with('#') {
                ("0101", imm_to_bin(parts[3], 6))            // ADDI: rs + immediate
            } else {
                ("0001", format!("000{}", reg_to_bin(parts[3]))) // ADD: rs + rt
            };

            binary_out.push_str(&format!("{}{}{}{}", opcode, dest, src1, src2_imm));
        }

        // Opcode: 0010
        "MOV" => {
            let opcode = "0010";
            let dest = reg_to_bin(parts[1]);
            let src1 = "000"; // MOV doesn't use a source 1 register
            let imm = imm_to_bin(parts[2], 6);
            
            binary_out.push_str(&format!("{}{}{}{}", opcode, dest, src1, imm));
        }

        // Opcode: 0011
        "CMP" => {
            let opcode = "0011";
            let dest = "000"; // Compare doesn't save to a destination vault
            let src1 = reg_to_bin(parts[1]);
            let src2 = format!("000{}", reg_to_bin(parts[2]));
            
            binary_out.push_str(&format!("{}{}{}{}", opcode, dest, src1, src2));
        }

        // Opcode: 0100
        "LDR" => {
            let opcode = "0100";
            let dest = reg_to_bin(parts[1]);
            let src1 = reg_to_bin(parts[2].trim_matches(|c| c == '[' || c == ']'));
            let imm = "000000"; // Assuming 0 offset for now
            
            binary_out.push_str(&format!("{}{}{}{}", opcode, dest, src1, imm));
        }

        // Opcode: 1000 (Branch if Negative)
        "BRn" => {
            let opcode = "1000";
            let condition = "100"; // Negative flag position
            let empty = "000";
            let target = imm_to_bin(parts[1], 6);
            
            binary_out.push_str(&format!("{}{}{}{}", opcode, condition, empty, target));
        }

        // Opcode: 1111
        "RET" => {
            binary_out.push_str("1111000000000000");
        }

        _ => {
            eprintln!("Unknown instruction: {}", instruction);
            return None;
        }
    }

    // Convert the 16-bit binary string into a 4-digit Hexadecimal string
    let int_val = u16::from_str_radix(&binary_out, 2).unwrap_or(0);
    Some(format!("{:04X}", int_val))
}

fn main() -> io::Result<()> {
    let input_file = File::open("test_kernel.asm")?;
    let reader = BufReader::new(input_file);
    
    let mut output_file = File::create("kernel.hex")?;

    println!("{:<20} | {:<18} | {:<4}", "Assembly", "Binary", "Hex");
    println!("{:-<50}", "");

    for line in reader.lines() {
        let line = line?;
        if let Some(hex_code) = assemble_line(&line) {
            
            // Print to terminal for verification
            let clean_line = line.split("//").next().unwrap_or("").trim();
            let bin_display = format!("{:016b}", u16::from_str_radix(&hex_code, 16).unwrap());
            println!("{:<20} | {} | {}", clean_line, bin_display, hex_code);
            
            // Write strictly the hex data to the output file
            writeln!(output_file, "{}", hex_code)?;
        }
    }

    println!("{:-<50}", "");
    println!("Compilation successful! Wrote to kernel.hex");
    Ok(())
}
// tiny-gpu ML compiler: a quantized graph -> (data image, kernel, expected output).
//
//   models/*.json  --[lower]-->  legalize + fuse Linear/Relu
//                  --[plan]-->  byte image the host DMAs to address 0
//                  --[codegen]->  tiny-gpu assembly
//                  --[eval]---->  the bytes the hardware must emit
//
// The point of this file is that all three come from the SAME Model value. The
// old flow had a Python script choose a memory layout and a hand-written J++
// loop re-implement that choice independently; when they drifted the model
// silently predicted nonsense. Here the planner assigns every address and the
// code generator asks the planner for them, so they cannot disagree.
//
// Usage: cargo run --bin graph_compiler -- [models/foo.json]

use serde::Deserialize;
use std::collections::BTreeMap;
use std::fs;

// ---- hardware limits the compiler is required to respect ----
const ROM_WORDS: usize = 256; // program_memory.sv DEPTH (branch targets are 8-bit)
const MMIO_TX: usize = 63;    // lsu.sv: a STR to this address is the UART, not memory

// ---- graph IR (what the frontend writes) --------------------------------

#[derive(Deserialize)]
struct Tensor {
    shape: Vec<usize>,
    /// Present for constants (weights) and the graph input; absent for activations.
    #[serde(default)]
    data: Option<Vec<i32>>,
}

#[derive(Deserialize, Default)]
struct Attrs {
    #[serde(default)]
    shift: u32,
}

#[derive(Deserialize)]
struct Node {
    op: String,
    #[serde(default)]
    name: Option<String>,
    inputs: Vec<String>,
    output: String,
    #[serde(default)]
    attrs: Attrs,
}

#[derive(Deserialize)]
struct Graph {
    model_name: String,
    memory_budget_bytes: usize,
    tensors: BTreeMap<String, Tensor>,
    nodes: Vec<Node>,
}

// ---- lowered model (what codegen consumes) -------------------------------

struct Layer {
    name: String,
    in_features: usize,
    out_features: usize,
    /// FOUT Rd,#shift -> clamp(acc >>> (8+shift), 0, 255). 0..7.
    shift: u32,
    /// Row-major: weights[m*in_features + k] is output m's weight on input k.
    weights: Vec<i32>,
}

struct Model {
    model_name: String,
    memory_budget_bytes: usize,
    input: Vec<u8>,
    layers: Vec<Layer>,
}

/// Legalize + fuse. The graph must be a chain
///   Linear -> (Relu | <Argmax>) -> Linear -> ... -> Argmax
/// and every Linear is fused with its Relu into one FMAC loop + FOUT, because
/// FOUT is the only way the hardware can read a neuron back.
fn lower(g: Graph) -> Result<Model, String> {
    for n in &g.nodes {
        if !["Linear", "Relu", "Argmax"].contains(&n.op.as_str()) {
            return Err(format!("unsupported op '{}' (output {}): legal ops are Linear, Relu, Argmax", n.op, n.output));
        }
    }
    let tensor = |name: &str| g.tensors.get(name).ok_or_else(|| format!("undefined tensor {}", name));

    let first = g.nodes.first().ok_or("empty graph")?;
    let x0 = first.inputs.first().ok_or("first node has no input")?;
    let input: Vec<u8> = tensor(x0)?.data.as_ref()
        .ok_or_else(|| format!("graph input {} has no data", x0))?
        .iter().map(|&v| u8::try_from(v).map_err(|_| format!("input {}: value {} is not u8", x0, v)))
        .collect::<Result<_, _>>()?;

    let mut layers = Vec::new();
    let (mut cur, mut width) = (x0.clone(), input.len());
    let mut it = g.nodes.iter().peekable();
    while let Some(n) = it.next() {
        match n.op.as_str() {
            "Linear" => {
                let (x, w) = match n.inputs.as_slice() {
                    [x, w] => (x, w),
                    _ => return Err(format!("Linear {}: expected [x, w] (bias is not supported by the hardware)", n.output)),
                };
                if *x != cur {
                    return Err(format!("Linear {}: input {} is not the previous output {} (only chains are supported)", n.output, x, cur));
                }
                let wt = tensor(w)?;
                let data = wt.data.as_ref().ok_or_else(|| format!("weight {} has no data", w))?;
                let (out_f, in_f) = match wt.shape.as_slice() {
                    [o, i] => (*o, *i),
                    s => return Err(format!("weight {}: shape {:?}, expected [out, in]", w, s)),
                };
                if in_f != width {
                    return Err(format!("Linear {}: weight {} expects {} inputs, got {}", n.output, w, in_f, width));
                }
                // FOUT always clamps at 0, so a Linear only lowers when its
                // consumer is Relu (exact) or Argmax (see below).
                let next = it.peek().map(|m| (m.op.as_str(), m.inputs == [n.output.clone()], m.output.clone()));
                cur = match next {
                    Some(("Relu", true, out)) => { it.next(); out }
                    // ponytail: Linear->Argmax lowers through FOUT's ReLU clamp too, so
                    // negative logits tie at 0 and argmax picks the first. Exact fix = FACC
                    // 32-bit compare, if calibration shows the clamp costs accuracy.
                    Some(("Argmax", true, _)) => n.output.clone(),
                    _ => return Err(format!("Linear {} is not followed by Relu or Argmax: a bare Linear has no lowering", n.output)),
                };
                layers.push(Layer {
                    name: n.name.clone().unwrap_or_else(|| n.output.clone()),
                    in_features: in_f,
                    out_features: out_f,
                    shift: n.attrs.shift,
                    weights: data.clone(),
                });
                width = out_f;
            }
            "Argmax" => {
                if n.inputs != [cur.clone()] || it.peek().is_some() {
                    return Err(format!("Argmax {} must be the last node and consume {}", n.output, cur));
                }
                if layers.is_empty() {
                    return Err("Argmax with no Linear before it".into());
                }
                return Ok(Model { model_name: g.model_name, memory_budget_bytes: g.memory_budget_bytes, input, layers });
            }
            _ => return Err(format!("Relu {} does not follow a Linear", n.output)),
        }
    }
    Err("graph does not end in Argmax (the epilogue emits scores + argmax)".into())
}

/// Where every tensor lives, and the bytes the host must load.
struct Plan {
    /// x[0] = input, x[i+1] = layer i's output buffer.
    x: Vec<usize>,
    /// w[i] = layer i's weight block.
    w: Vec<usize>,
    /// Bytes to DMA to address 0. Covers the input and all weights; the
    /// activation buffers live past the end and are written by the GPU.
    image: Vec<u8>,
    total: usize,
}

fn plan(m: &Model) -> Result<Plan, String> {
    let mut image: Vec<u8> = Vec::new();
    let mut x = vec![0usize];
    let mut w = Vec::new();

    // Everything the host has to supply goes first, contiguously from address 0,
    // because the DMA writes the payload sequentially starting there.
    image.extend_from_slice(&m.input);
    for l in &m.layers {
        w.push(image.len());
        if l.weights.len() != l.in_features * l.out_features {
            return Err(format!(
                "layer {}: {} weights but in_features*out_features = {}",
                l.name, l.weights.len(), l.in_features * l.out_features
            ));
        }
        for &v in &l.weights {
            if !(-128..=127).contains(&v) {
                return Err(format!("layer {}: weight {} is not int8", l.name, v));
            }
            image.push(v as i8 as u8);
        }
    }

    // Activation buffers: written by the GPU, never loaded, so they sit after
    // the image and cost nothing on the wire.
    let mut cursor = image.len();
    for l in &m.layers {
        x.push(cursor);
        cursor += l.out_features;
    }

    Ok(Plan { x, w, image, total: cursor })
}

/// Reject anything the hardware would execute incorrectly, instead of emitting
/// a program that silently computes the wrong thing.
fn check(m: &Model, p: &Plan) -> Result<(), String> {
    if p.total > m.memory_budget_bytes {
        return Err(format!(
            "out of memory: model needs {} bytes, main_memory.sv holds {}",
            p.total, m.memory_budget_bytes
        ));
    }
    // A store to address 63 goes to the UART instead of memory, so no buffer the
    // GPU WRITES may contain it. (Read-only tensors are fine.)
    for (i, l) in m.layers.iter().enumerate() {
        let (lo, hi) = (p.x[i + 1], p.x[i + 1] + l.out_features);
        if (lo..hi).contains(&MMIO_TX) {
            return Err(format!(
                "layer {} output spans address {} (the memory-mapped UART)",
                l.name, MMIO_TX
            ));
        }
        if l.shift > 7 {
            return Err(format!("layer {}: shift {} exceeds FOUT's 3-bit field", l.name, l.shift));
        }
        // fc_mac accumulates in 32 bits; prove the worst case cannot wrap.
        let worst = (l.in_features as i64) * 255 * 128;
        if worst > i32::MAX as i64 {
            return Err(format!(
                "layer {}: {} taps can overflow the 32-bit accumulator (worst case {})",
                l.name, l.in_features, worst
            ));
        }
    }
    Ok(())
}

// ---- codegen ------------------------------------------------------------

/// Load a constant: one word when it fits the 6-bit MOV immediate, else the
/// 3-word LDI expansion.
fn lit(reg: usize, val: usize) -> String {
    if val <= 63 {
        format!("    MOV  R{}, #{}", reg, val)
    } else {
        format!("    LDI  R{}, #{}", reg, val)
    }
}

// Register plan, per layer kernel:
//   R0 weight pointer (walks the whole row-major block, never resets)
//   R1 feature pointer (reset to the layer's input base for each neuron)
//   R2 feature end pointer (input base + K)
//   R3 output pointer
//   R4/R5 scratch: the loaded feature and weight
//   R6 output end pointer
//   R7 the requantized neuron output
fn gen_layer(asm: &mut Vec<String>, i: usize, l: &Layer, p: &Plan) {
    let (xin, xout, wb) = (p.x[i], p.x[i + 1], p.w[i]);
    let (outer, inner, done_in, end) = (
        format!("L{}_neuron", i), format!("L{}_tap", i),
        format!("L{}_fire", i), format!("L{}_end", i),
    );

    asm.push(format!("// ---- layer {} : {} -> {} , acc >>> {} , relu ----",
                     l.name, l.in_features, l.out_features, 8 + l.shift));
    asm.push(lit(0, wb));
    asm.push(lit(2, xin + l.in_features));
    asm.push(lit(3, xout));
    asm.push(lit(6, xout + l.out_features));

    asm.push(format!("{}:", outer));
    asm.push("    CMP  R3, R6".into());
    asm.push(format!("    BRzp {}", end));          // out_ptr >= out_end -> layer done
    asm.push(lit(1, xin));                          // restart the input vector

    asm.push(format!("{}:", inner));
    asm.push("    CMP  R1, R2".into());
    asm.push(format!("    BRzp {}", done_in));
    asm.push("    LDR  R4, [R1]".into());           // feature
    asm.push("    LDR  R5, [R0]".into());           // weight
    asm.push("    FMAC R4, R5".into());             // acc += feature * weight (32-bit)
    asm.push("    ADDI R1, R1, #1".into());
    asm.push("    ADDI R0, R0, #1".into());
    asm.push(format!("    BR   {}", inner));

    asm.push(format!("{}:", done_in));
    asm.push(format!("    FOUT R7, #{}", l.shift)); // requantize + saturate + ReLU, clears acc
    asm.push("    STR  R7, [R3]".into());
    asm.push("    ADDI R3, R3, #1".into());
    asm.push(format!("    BR   {}", outer));
    asm.push(format!("{}:", end));
}

/// Emit every score of the last layer, then the argmax, as [len][scores][pred].
/// Emitting the scores (not just the prediction) is what makes the result
/// checkable: a wrong weight changes a score, whereas argmax hides it.
fn gen_epilogue(asm: &mut Vec<String>, m: &Model, p: &Plan) {
    let last = m.layers.len() - 1;
    let (xl, n) = (p.x[last + 1], m.layers[last].out_features);

    asm.push("// ---- emit [len][scores...][argmax] ----".into());
    asm.push(lit(2, MMIO_TX));
    asm.push(lit(3, n + 1));
    asm.push("    STR  R3, [R2]".into());           // frame length
    asm.push(lit(0, xl));
    asm.push(lit(1, xl + n));
    asm.push("    MOV  R4, #0".into());             // best score
    asm.push("    MOV  R5, #0".into());             // best index
    asm.push("    MOV  R6, #0".into());             // current index
    asm.push("Lemit:".into());
    asm.push("    CMP  R0, R1".into());
    asm.push("    BRzp Lemit_done".into());
    asm.push("    LDR  R7, [R0]".into());
    asm.push("    STR  R7, [R2]".into());           // emit this score
    asm.push("    CMP  R7, R4".into());
    asm.push("    BRnz Lemit_next".into());         // skip unless score > best
    asm.push("    ADDI R4, R7, #0".into());
    asm.push("    ADDI R5, R6, #0".into());
    asm.push("Lemit_next:".into());
    asm.push("    ADDI R6, R6, #1".into());
    asm.push("    ADDI R0, R0, #1".into());
    asm.push("    BR   Lemit".into());
    asm.push("Lemit_done:".into());
    asm.push("    STR  R5, [R2]".into());           // the prediction
    asm.push("    RET".into());
    asm.push("    RET  // sacrificial: the UART->DMA loader can drop the last word".into());
}

/// Words the assembler will emit, so the 256-word ROM limit is a compile error
/// rather than a wrapped branch target at runtime.
fn word_count(asm: &[String]) -> usize {
    asm.iter()
        .filter_map(|l| {
            let t = l.trim();
            if t.is_empty() || t.starts_with("//") || t.ends_with(':') {
                return None;
            }
            let mnem = t.split_whitespace().next().unwrap_or("");
            Some(match mnem {
                "LDI" => 3,
                "MAX" => 4,
                _ => 1,
            })
        })
        .sum()
}

// ---- reference ----------------------------------------------------------

/// Bit-exact model of what the hardware computes, from the same Model the code
/// was generated from. `acc >>> (8+shift)` with a low clamp of 0 mirrors
/// fc_mac.sv's relu_out exactly, including saturation.
fn eval(m: &Model) -> (Vec<Vec<u8>>, usize) {
    let mut acts: Vec<Vec<u8>> = Vec::new();
    let mut x: Vec<u8> = m.input.clone();
    for l in &m.layers {
        let mut out = Vec::with_capacity(l.out_features);
        for o in 0..l.out_features {
            let mut acc: i64 = 0;
            for k in 0..l.in_features {
                acc += (x[k] as i64) * (l.weights[o * l.in_features + k] as i64);
            }
            let s = acc >> (8 + l.shift); // arithmetic: negatives stay negative
            out.push(if s < 0 { 0 } else if s > 255 { 255 } else { s as u8 });
        }
        x = out.clone();
        acts.push(out);
    }
    // argmax, first-wins, matching the epilogue's strict `>` comparison
    let scores = acts.last().unwrap();
    let mut best = 0usize;
    for (i, &v) in scores.iter().enumerate() {
        if v > scores[best] {
            best = i;
        }
    }
    (acts, best)
}

fn main() {
    let path = std::env::args().nth(1).unwrap_or_else(|| "models/mlp_169_32_10.json".into());
    let src = fs::read_to_string(&path).unwrap_or_else(|e| panic!("cannot read {}: {}", path, e));
    let graph: Graph = serde_json::from_str(&src).expect("bad graph JSON");
    let model = lower(graph).unwrap_or_else(|e| { eprintln!("ERROR: {}", e); std::process::exit(1) });

    let p = plan(&model).unwrap_or_else(|e| { eprintln!("ERROR: {}", e); std::process::exit(1) });
    check(&model, &p).unwrap_or_else(|e| { eprintln!("ERROR: {}", e); std::process::exit(1) });

    let mut asm = vec![format!("// {} - generated by graph_compiler, do not edit", model.model_name)];
    for (i, l) in model.layers.iter().enumerate() {
        gen_layer(&mut asm, i, l, &p);
    }
    gen_epilogue(&mut asm, &model, &p);

    let words = word_count(&asm);
    if words > ROM_WORDS {
        eprintln!("ERROR: kernel is {} words, instruction memory holds {}", words, ROM_WORDS);
        std::process::exit(1);
    }

    let (acts, pred) = eval(&model);
    let scores = acts.last().unwrap();

    fs::create_dir_all("build").unwrap();
    let base = format!("build/{}", model.model_name);
    fs::write(format!("{}.asm", base), asm.join("\n") + "\n").unwrap();
    fs::write(
        format!("{}.data.hex", base),
        p.image.iter().map(|b| format!("{:02X}\n", b)).collect::<String>(),
    ).unwrap();
    let mut expect: Vec<u8> = vec![(scores.len() + 1) as u8];
    expect.extend_from_slice(scores);
    expect.push(pred as u8);
    fs::write(
        format!("{}.expect.hex", base),
        expect.iter().map(|b| format!("{:02X}\n", b)).collect::<String>(),
    ).unwrap();

    println!("model  {}", model.model_name);
    for (i, l) in model.layers.iter().enumerate() {
        println!(
            "  layer {:<4} {:>4} -> {:<4} weights@{:<6} out@{:<6} acc>>>{}",
            l.name, l.in_features, l.out_features, p.w[i], p.x[i + 1], 8 + l.shift
        );
    }
    println!("memory {} / {} bytes  ({} loaded, {} GPU-written)",
             p.total, model.memory_budget_bytes, p.image.len(), p.total - p.image.len());
    println!("kernel {} / {} words", words, ROM_WORDS);
    println!("scores {:?}", scores);
    println!("pred   {}", pred);
    println!("wrote  {}.asm  {}.data.hex  {}.expect.hex", base, base, base);
}

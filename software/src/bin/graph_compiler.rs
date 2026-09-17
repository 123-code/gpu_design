// tiny-gpu ML compiler: a quantized graph -> (data image, kernel, expected output).
//
//   models/*.json  --[lower]-->  legalize + fuse (Linear/Conv2d + Relu, MaxPool2d, Flatten)
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
const IMM_MAX: usize = 63;    // ADDI / MOV immediates are 6-bit unsigned

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
    #[serde(default)]
    kernel_size: Option<usize>,
    #[serde(default)]
    stride: Option<usize>,
    #[serde(default)]
    padding: Option<usize>,
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

enum Kind {
    /// Linear (+ Relu). Row-major: weights[m*in_f + k] is output m's weight on input k.
    Dense { in_f: usize, out_f: usize, shift: u32, weights: Vec<i32> },
    /// Conv2d 1->cout, KxK, stride 1, no padding (+ Relu).
    /// weights[m*k*k + ky*k + kx]; output is [cout, h-k+1, w-k+1], channel-major.
    Conv { h: usize, w: usize, cout: usize, k: usize, shift: u32, weights: Vec<i32> },
    /// MaxPool2d kxk, stride k, over [c, h, w]; output [c, h/k, w/k].
    Pool { c: usize, h: usize, w: usize, k: usize },
}

struct Layer {
    name: String,
    kind: Kind,
}

impl Layer {
    fn out_len(&self) -> usize {
        match &self.kind {
            Kind::Dense { out_f, .. } => *out_f,
            Kind::Conv { h, w, cout, k, .. } => cout * (h - k + 1) * (w - k + 1),
            Kind::Pool { c, h, w, k } => c * (h / k) * (w / k),
        }
    }
    fn weights(&self) -> &[i32] {
        match &self.kind {
            Kind::Dense { weights, .. } | Kind::Conv { weights, .. } => weights,
            Kind::Pool { .. } => &[],
        }
    }
}

struct Model {
    model_name: String,
    memory_budget_bytes: usize,
    input: Vec<u8>,
    layers: Vec<Layer>,
}

/// Legalize + fuse. The graph must be a chain ending in Argmax, over
///   Conv2d -> Relu | MaxPool2d | Flatten | Linear -> (Relu | <Argmax>)
/// Every Conv2d and Linear is fused with its Relu into FMAC loops + FOUT, because
/// FOUT is the only way the hardware can read a neuron back.
fn lower(g: Graph) -> Result<Model, String> {
    const LEGAL: [&str; 6] = ["Linear", "Conv2d", "MaxPool2d", "Flatten", "Relu", "Argmax"];
    for n in &g.nodes {
        if !LEGAL.contains(&n.op.as_str()) {
            return Err(format!("unsupported op '{}' (output {}): legal ops are {}", n.op, n.output, LEGAL.join(", ")));
        }
    }
    let tensor = |name: &str| g.tensors.get(name).ok_or_else(|| format!("undefined tensor {}", name));

    let first = g.nodes.first().ok_or("empty graph")?;
    let x0 = first.inputs.first().ok_or("first node has no input")?;
    let x0t = tensor(x0)?;
    let input: Vec<u8> = x0t.data.as_ref()
        .ok_or_else(|| format!("graph input {} has no data", x0))?
        .iter().map(|&v| u8::try_from(v).map_err(|_| format!("input {}: value {} is not u8", x0, v)))
        .collect::<Result<_, _>>()?;
    if x0t.shape.iter().product::<usize>() != input.len() {
        return Err(format!("input {}: shape {:?} does not match {} data bytes", x0, x0t.shape, input.len()));
    }

    let mut layers = Vec::new();
    let (mut cur, mut shape) = (x0.clone(), x0t.shape.clone());
    let mut it = g.nodes.iter().peekable();
    while let Some(n) = it.next() {
        if n.inputs.first() != Some(&cur) {
            return Err(format!("{} {}: input {:?} is not the previous output {} (only chains are supported)",
                               n.op, n.output, n.inputs.first(), cur));
        }
        let name = n.name.clone().unwrap_or_else(|| n.output.clone());
        let weight = |n: &Node| -> Result<(&Tensor, Vec<i32>), String> {
            match n.inputs.as_slice() {
                [_, w] => {
                    let wt = tensor(w)?;
                    Ok((wt, wt.data.clone().ok_or_else(|| format!("weight {} has no data", w))?))
                }
                _ => Err(format!("{} {}: expected [x, w] (bias is not supported by the hardware)", n.op, n.output)),
            }
        };
        // FOUT always clamps at 0, so a Linear/Conv2d only lowers when its
        // consumer is Relu (exact) or, for Linear, Argmax (see below).
        let next = it.peek().map(|m| (m.op.clone(), m.inputs == [n.output.clone()], m.output.clone()));
        match n.op.as_str() {
            "Linear" => {
                let (wt, data) = weight(n)?;
                let (out_f, in_f) = match wt.shape.as_slice() {
                    [o, i] => (*o, *i),
                    s => return Err(format!("weight {}: shape {:?}, expected [out, in]", n.inputs[1], s)),
                };
                if shape.len() != 1 || shape[0] != in_f {
                    return Err(format!("Linear {}: weight {} expects [{}], got {:?} (insert Flatten)", n.output, n.inputs[1], in_f, shape));
                }
                cur = match next {
                    Some((op, true, out)) if op == "Relu" => { it.next(); out }
                    // ponytail: Linear->Argmax lowers through FOUT's ReLU clamp too, so
                    // negative logits tie at 0 and argmax picks the first. Exact fix = FACC
                    // 32-bit compare, if calibration shows the clamp costs accuracy.
                    Some((op, true, _)) if op == "Argmax" => n.output.clone(),
                    _ => return Err(format!("Linear {} is not followed by Relu or Argmax: a bare Linear has no lowering", n.output)),
                };
                layers.push(Layer { name, kind: Kind::Dense { in_f, out_f, shift: n.attrs.shift, weights: data } });
                shape = vec![out_f];
            }
            "Conv2d" => {
                let (wt, data) = weight(n)?;
                let (cout, cin, k) = match wt.shape.as_slice() {
                    [o, i, kh, kw] if kh == kw => (*o, *i, *kh),
                    s => return Err(format!("Conv2d {}: weight shape {:?}, expected square [out, in, k, k]", n.output, s)),
                };
                let (h, w) = match shape.as_slice() {
                    [1, h, w] => (*h, *w),
                    s => return Err(format!("Conv2d {}: input shape {:?}, expected [1, h, w]", n.output, s)),
                };
                // ponytail: one input channel only (a first-layer conv). Conv after conv
                // needs a plane-skip in the tap walk; add it when a model needs it.
                if cin != 1 {
                    return Err(format!("Conv2d {}: in_channels = {} (only 1 is supported)", n.output, cin));
                }
                if n.attrs.stride.unwrap_or(1) != 1 || n.attrs.padding.unwrap_or(0) != 0 {
                    return Err(format!("Conv2d {}: only stride 1, padding 0 are supported", n.output));
                }
                if k > h || k > w {
                    return Err(format!("Conv2d {}: kernel {} larger than input {}x{}", n.output, k, h, w));
                }
                cur = match next {
                    Some((op, true, out)) if op == "Relu" => { it.next(); out }
                    _ => return Err(format!("Conv2d {} is not followed by Relu: a bare Conv2d has no lowering", n.output)),
                };
                layers.push(Layer { name, kind: Kind::Conv { h, w, cout, k, shift: n.attrs.shift, weights: data } });
                shape = vec![cout, h - k + 1, w - k + 1];
            }
            "MaxPool2d" => {
                let k = n.attrs.kernel_size.ok_or_else(|| format!("MaxPool2d {}: missing kernel_size", n.output))?;
                if n.attrs.stride.unwrap_or(k) != k || n.attrs.padding.unwrap_or(0) != 0 {
                    return Err(format!("MaxPool2d {}: only stride = kernel_size, padding 0 are supported", n.output));
                }
                let (c, h, w) = match shape.as_slice() {
                    [c, h, w] if k >= 1 && *h >= k && *w >= k => (*c, *h, *w),
                    s => return Err(format!("MaxPool2d {}: input shape {:?} cannot take a {}x{} window", n.output, s, k, k)),
                };
                layers.push(Layer { name, kind: Kind::Pool { c, h, w, k } });
                shape = vec![c, h / k, w / k];
                cur = n.output.clone();
            }
            "Flatten" => {
                // no code: the buffer is already contiguous, channel-major, row-major
                shape = vec![shape.iter().product()];
                cur = n.output.clone();
            }
            "Argmax" => {
                if it.peek().is_some() {
                    return Err(format!("Argmax {} must be the last node", n.output));
                }
                if layers.is_empty() {
                    return Err("Argmax with no layer before it".into());
                }
                return Ok(Model { model_name: g.model_name, memory_budget_bytes: g.memory_budget_bytes, input, layers });
            }
            _ => return Err(format!("Relu {} does not follow a Linear or Conv2d", n.output)),
        }
    }
    Err("graph does not end in Argmax (the epilogue emits scores + argmax)".into())
}

/// Where every tensor lives, and the bytes the host must load.
struct Plan {
    /// x[0] = input, x[i+1] = layer i's output buffer.
    x: Vec<usize>,
    /// w[i] = layer i's weight block (unused for weightless layers).
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
        let want = match &l.kind {
            Kind::Dense { in_f, out_f, .. } => in_f * out_f,
            Kind::Conv { cout, k, .. } => cout * k * k,
            Kind::Pool { .. } => 0,
        };
        if l.weights().len() != want {
            return Err(format!("layer {}: {} weights, shape needs {}", l.name, l.weights().len(), want));
        }
        for &v in l.weights() {
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
        // a store to MMIO_TX is the UART, not memory: never place a GPU-written buffer over it
        if (cursor..cursor + l.out_len()).contains(&MMIO_TX) {
            cursor = MMIO_TX + 1;
        }
        x.push(cursor);
        cursor += l.out_len();
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
    for (i, l) in m.layers.iter().enumerate() {
        // A store to address 63 goes to the UART instead of memory, so no buffer the
        // GPU WRITES may contain it. (Read-only tensors are fine.)
        let (lo, hi) = (p.x[i + 1], p.x[i + 1] + l.out_len());
        if (lo..hi).contains(&MMIO_TX) {
            return Err(format!("layer {} output spans address {} (the memory-mapped UART)", l.name, MMIO_TX));
        }
        let (shift, taps) = match &l.kind {
            Kind::Dense { in_f, shift, .. } => (*shift, *in_f),
            Kind::Conv { w, k, shift, .. } => {
                // the window walk steps by these as 6-bit immediates
                if w - k + 1 > IMM_MAX || k * k > IMM_MAX {
                    return Err(format!("layer {}: width {} / kernel {} exceed the 6-bit pointer step", l.name, w, k));
                }
                (*shift, k * k)
            }
            Kind::Pool { w, k, .. } => {
                if w - k + 1 > IMM_MAX || *k > IMM_MAX {
                    return Err(format!("layer {}: width {} / kernel {} exceed the 6-bit pointer step", l.name, w, k));
                }
                continue;
            }
        };
        if shift > 7 {
            return Err(format!("layer {}: shift {} exceeds FOUT's 3-bit field", l.name, shift));
        }
        // fc_mac accumulates in 32 bits; prove the worst case cannot wrap.
        let worst = (taps as i64) * 255 * 128;
        if worst > i32::MAX as i64 {
            return Err(format!("layer {}: {} taps can overflow the 32-bit accumulator (worst case {})", l.name, taps, worst));
        }
    }
    let n = m.layers.last().unwrap().out_len();
    if n + 1 > 255 {
        return Err(format!("final layer has {} outputs; the reply length is one byte", n));
    }
    Ok(())
}

// ---- codegen ------------------------------------------------------------

/// Load a constant: one word when it fits the 6-bit MOV immediate, else the
/// 3-word LDI expansion.
fn lit(reg: usize, val: usize) -> String {
    if val <= IMM_MAX {
        format!("    MOV  R{}, #{}", reg, val)
    } else {
        format!("    LDI  R{}, #{}", reg, val)
    }
}

/// reg += val, via one ADDI when it fits, else LDI into `scratch` + ADD.
fn bump(asm: &mut Vec<String>, reg: usize, val: usize, scratch: usize) {
    if val == 0 {
    } else if val <= IMM_MAX {
        asm.push(format!("    ADDI R{}, R{}, #{}", reg, reg, val));
    } else {
        asm.push(lit(scratch, val));
        asm.push(format!("    ADD  R{}, R{}, R{}", reg, reg, scratch));
    }
}

// Register plan, per Dense kernel:
//   R0 weight pointer (walks the whole row-major block, never resets)
//   R1 feature pointer (reset to the layer's input base for each neuron)
//   R2 feature end pointer (input base + K)
//   R3 output pointer
//   R4/R5 scratch: the loaded feature and weight
//   R6 output end pointer
//   R7 the requantized neuron output
fn gen_dense(asm: &mut Vec<String>, i: usize, l: &Layer, p: &Plan) {
    let Kind::Dense { in_f, out_f, shift, .. } = l.kind else { unreachable!() };
    let (xin, xout, wb) = (p.x[i], p.x[i + 1], p.w[i]);
    let (outer, inner, done_in, end) = (
        format!("L{}_neuron", i), format!("L{}_tap", i),
        format!("L{}_fire", i), format!("L{}_end", i),
    );

    asm.push(format!("// ---- layer {} : {} -> {} , acc >>> {} , relu ----", l.name, in_f, out_f, 8 + shift));
    asm.push(lit(0, wb));
    asm.push(lit(2, xin + in_f));
    asm.push(lit(3, xout));
    asm.push(lit(6, xout + out_f));

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
    asm.push(format!("    FOUT R7, #{}", shift));   // requantize + saturate + ReLU, clears acc
    asm.push("    STR  R7, [R3]".into());
    asm.push("    ADDI R3, R3, #1".into());
    asm.push(format!("    BR   {}", outer));
    asm.push(format!("{}:", end));
}

// Register plan, per Conv kernel (one output pixel = one neuron over a KxK window):
//   R0 this channel's weight base      R1 window top-left pointer (walks the input)
//   R2 input tap pointer               R3 output pointer
//   R4/R5 scratch (pixel, weight)      R6 weight tap pointer
//   R7 end of this output row, in R1 space
// The K*K taps are unrolled at compile time: K is known, and unrolling costs
// fewer words than a tap loop that would need two more registers.
fn gen_conv(asm: &mut Vec<String>, i: usize, l: &Layer, p: &Plan) {
    let Kind::Conv { h, w, cout, k, shift, .. } = l.kind else { unreachable!() };
    let (xin, xout, wb) = (p.x[i], p.x[i + 1], p.w[i]);
    let (oh, ow) = (h - k + 1, w - k + 1);
    let lb = |s: &str| format!("L{}_{}", i, s);

    asm.push(format!("// ---- layer {} : conv {}x{} 1 -> {} on {}x{} , acc >>> {} , relu ----",
                     l.name, k, k, cout, h, w, 8 + shift));
    asm.push(lit(0, wb));
    asm.push(lit(3, xout));
    asm.push(format!("{}:", lb("chan")));
    asm.push(lit(5, xout + l.out_len()));
    asm.push("    CMP  R3, R5".into());
    asm.push(format!("    BRzp {}", lb("end")));
    asm.push(lit(1, xin));                          // every channel slides over the same input
    asm.push(format!("{}:", lb("row")));
    asm.push(lit(5, xin + oh * w));
    asm.push("    CMP  R1, R5".into());
    asm.push(format!("    BRzp {}", lb("chan_next")));
    if ow <= IMM_MAX {
        asm.push(format!("    ADDI R7, R1, #{}", ow));
    } else {
        asm.push(lit(7, ow));
        asm.push("    ADD  R7, R7, R1".into());
    }
    asm.push(format!("{}:", lb("pix")));
    asm.push("    CMP  R1, R7".into());
    asm.push(format!("    BRzp {}", lb("row_next")));
    asm.push("    ADDI R2, R1, #0".into());
    asm.push("    ADDI R6, R0, #0".into());
    for ky in 0..k {
        for kx in 0..k {
            asm.push("    LDR  R4, [R2]".into());   // pixel
            asm.push("    LDR  R5, [R6]".into());   // weight
            asm.push("    FMAC R4, R5".into());
            if (ky, kx) != (k - 1, k - 1) {
                asm.push("    ADDI R6, R6, #1".into());
                let step = if kx + 1 < k { 1 } else { w - k + 1 };
                asm.push(format!("    ADDI R2, R2, #{}", step));
            }
        }
    }
    asm.push(format!("    FOUT R4, #{}", shift));   // requantize + saturate + ReLU, clears acc
    asm.push("    STR  R4, [R3]".into());
    asm.push("    ADDI R3, R3, #1".into());
    asm.push("    ADDI R1, R1, #1".into());
    asm.push(format!("    BR   {}", lb("pix")));
    asm.push(format!("{}:", lb("row_next")));
    bump(asm, 1, k - 1, 5);                          // row start + OW -> next row start
    asm.push(format!("    BR   {}", lb("row")));
    asm.push(format!("{}:", lb("chan_next")));
    bump(asm, 0, k * k, 5);                          // next channel's weights
    asm.push(format!("    BR   {}", lb("chan")));
    asm.push(format!("{}:", lb("end")));
}

// Register plan, per MaxPool kernel:
//   R0 end of this channel's output    R1 window top-left pointer (walks the input)
//   R2 tap pointer                     R3 output pointer
//   R4 running max   R5 loaded value   R6 scratch for wide constants
//   R7 end of this output row, in R3 space
fn gen_pool(asm: &mut Vec<String>, i: usize, l: &Layer, p: &Plan) {
    let Kind::Pool { c, h, w, k } = l.kind else { unreachable!() };
    let (xin, xout) = (p.x[i], p.x[i + 1]);
    let (oh, ow) = (h / k, w / k);
    let lb = |s: &str| format!("L{}_{}", i, s);

    asm.push(format!("// ---- layer {} : maxpool {}x{} on {}x{}x{} ----", l.name, k, k, c, h, w));
    asm.push(lit(1, xin));
    asm.push(lit(3, xout));
    asm.push(lit(0, xout));
    asm.push(format!("{}:", lb("chan")));
    asm.push(lit(5, xout + l.out_len()));
    asm.push("    CMP  R3, R5".into());
    asm.push(format!("    BRzp {}", lb("end")));
    bump(asm, 0, oh * ow, 6);
    asm.push(format!("{}:", lb("row")));
    asm.push("    CMP  R3, R0".into());
    asm.push(format!("    BRzp {}", lb("chan_next")));
    if ow <= IMM_MAX {
        asm.push(format!("    ADDI R7, R3, #{}", ow));
    } else {
        asm.push(lit(7, ow));
        asm.push("    ADD  R7, R7, R3".into());
    }
    asm.push(format!("{}:", lb("pix")));
    asm.push("    CMP  R3, R7".into());
    asm.push(format!("    BRzp {}", lb("row_next")));
    asm.push("    LDR  R4, [R1]".into());
    asm.push("    ADDI R2, R1, #0".into());
    for t in 1..k * k {
        let step = if t % k != 0 { 1 } else { w - k + 1 };
        asm.push(format!("    ADDI R2, R2, #{}", step));
        asm.push("    LDR  R5, [R2]".into());
        asm.push("    MAX  R4, R4, R5".into());
    }
    asm.push("    STR  R4, [R3]".into());
    asm.push("    ADDI R3, R3, #1".into());
    asm.push(format!("    ADDI R1, R1, #{}", k));
    asm.push(format!("    BR   {}", lb("pix")));
    asm.push(format!("{}:", lb("row_next")));
    bump(asm, 1, k * (w - ow), 6);                  // skip the rest of this window row + k-1 rows
    asm.push(format!("    BR   {}", lb("row")));
    asm.push(format!("{}:", lb("chan_next")));
    bump(asm, 1, (h - k * oh) * w, 6);              // rows the floor division dropped
    asm.push(format!("    BR   {}", lb("chan")));
    asm.push(format!("{}:", lb("end")));
}

/// Emit every score of the last layer, then the argmax, as [len][scores][pred].
/// Emitting the scores (not just the prediction) is what makes the result
/// checkable: a wrong weight changes a score, whereas argmax hides it.
fn gen_epilogue(asm: &mut Vec<String>, m: &Model, p: &Plan) {
    let last = m.layers.len() - 1;
    let (xl, n) = (p.x[last + 1], m.layers[last].out_len());

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

/// FOUT, bit-exact: arithmetic shift, then clamp to 0..255 (fc_mac.sv relu_out).
fn fout(acc: i64, shift: u32) -> u8 {
    (acc >> (8 + shift)).clamp(0, 255) as u8
}

/// Bit-exact model of what the hardware computes, from the same Model the code
/// was generated from.
fn eval(m: &Model) -> (Vec<Vec<u8>>, usize) {
    let mut acts: Vec<Vec<u8>> = Vec::new();
    let mut x: Vec<u8> = m.input.clone();
    for l in &m.layers {
        let out: Vec<u8> = match &l.kind {
            Kind::Dense { in_f, out_f, shift, weights } => (0..*out_f)
                .map(|o| fout((0..*in_f).map(|k| x[k] as i64 * weights[o * in_f + k] as i64).sum(), *shift))
                .collect(),
            Kind::Conv { h, w, cout, k, shift, weights } => {
                let (oh, ow) = (h - k + 1, w - k + 1);
                let mut out = Vec::with_capacity(l.out_len());
                for c in 0..*cout {
                    for oy in 0..oh {
                        for ox in 0..ow {
                            let mut acc = 0i64;
                            for ky in 0..*k {
                                for kx in 0..*k {
                                    acc += x[(oy + ky) * w + ox + kx] as i64 * weights[c * k * k + ky * k + kx] as i64;
                                }
                            }
                            out.push(fout(acc, *shift));
                        }
                    }
                }
                out
            }
            Kind::Pool { c, h, w, k } => {
                let (oh, ow) = (h / k, w / k);
                let mut out = Vec::with_capacity(l.out_len());
                for ch in 0..*c {
                    for oy in 0..oh {
                        for ox in 0..ow {
                            let mut best = 0u8;
                            for ky in 0..*k {
                                for kx in 0..*k {
                                    best = best.max(x[ch * h * w + (oy * k + ky) * w + ox * k + kx]);
                                }
                            }
                            out.push(best);
                        }
                    }
                }
                out
            }
        };
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
        match l.kind {
            Kind::Dense { .. } => gen_dense(&mut asm, i, l, &p),
            Kind::Conv { .. } => gen_conv(&mut asm, i, l, &p),
            Kind::Pool { .. } => gen_pool(&mut asm, i, l, &p),
        }
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
        let what = match &l.kind {
            Kind::Dense { in_f, out_f, shift, .. } => format!("linear {} -> {}, acc>>>{}", in_f, out_f, 8 + shift),
            Kind::Conv { h, w, cout, k, shift, .. } => format!("conv{}x{} 1x{}x{} -> {}, acc>>>{}", k, k, h, w, cout, 8 + shift),
            Kind::Pool { c, h, w, k } => format!("maxpool{}x{} {}x{}x{}", k, k, c, h, w),
        };
        println!("  layer {:<8} {:<34} weights@{:<6} out@{:<6} ({} bytes)",
                 l.name, what, p.w[i], p.x[i + 1], l.out_len());
    }
    println!("memory {} / {} bytes  ({} loaded, {} GPU-written)",
             p.total, model.memory_budget_bytes, p.image.len(), p.total - p.image.len());
    println!("kernel {} / {} words", words, ROM_WORDS);
    println!("scores {:?}", scores);
    println!("pred   {}", pred);
    println!("wrote  {}.asm  {}.data.hex  {}.expect.hex", base, base, base);
}

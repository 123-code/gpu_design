`default_nettype none
`timescale 1ns/1ns


module fpu (
input logic [31:0] num_1,
input logic [31:0] num_2,

output logic [31:0] sum
);
localparam int TARGET_INDEX = 23;

wire final_sign;
logic do_subtract;

// first we will slice the 32 bit inputs and get the exponents, in order to check which number is bigger
logic [7:0] exponent_1,exponent_2;
assign exponent_1 = num_1[30:23];
assign exponent_2 = num_2[30:23];

// now we try extracting the mantissa, and concatenating the implicit 1 at the beggining of it
logic [23:0] mantissa_1,mantissa_2;
assign mantissa_1 = {1'b1,num_1[22:0]};
assign mantissa_2 = {1'b1,num_2[22:0]};

//extract the sign 
logic sign_1,sign_2;
assign sign_1 = num_1[31];
assign sign_2 = num_2[31];

// now we need to know the exact difference between our exponents so we shift
// the smallest mantissa to the right by that amount 
logic [7:0] exp_diff;
logic [7:0] larger_exp;
logic [24:0] mantissa_sum;
logic [23:0] larger_mantissa;
logic [23:0] smaller_mantissa;
logic [23:0] aligned_smaller;
logic [7:0] top_bits;
logic [7:0] shift_amount;
logic [22:0] normalized_fraction;
logic [7:0] normalized_exp;
logic [22:0] shifted_sum;

assign larger_exp = (exponent_1   > exponent_2) ? exponent_1 : exponent_2;
assign exp_diff = (exponent_1 > exponent_2) ? exponent_1 - exponent_2 : exponent_2 - exponent_1;
assign larger_mantissa = (exponent_1   > exponent_2) ? mantissa_1:mantissa_2;
assign smaller_mantissa = (exponent_1   > exponent_2) ? mantissa_2:mantissa_1;
assign aligned_smaller = smaller_mantissa >> exp_diff;

//getting the final sign of the number by comparing the two exponents, we assign the sign of the larger one
assign final_sign = (exponent_1 > exponent_2) ? sign_1 : sign_2;
//if signs are different we subtract the smaller mantissa from the larger one
assign do_subtract = sign_1 ^ sign_2;

//add or subtract the two mantissas depending on sign
assign mantissa_sum = do_subtract ? (larger_mantissa - aligned_smaller)
                                  : (larger_mantissa + aligned_smaller);

//priority encoder loop to find the 1 that should lead the number. save number of preceding 0's to top_bits
always_comb begin : count_leading_zeros
    top_bits = 0;
    for(int i = $size(mantissa_sum)-1;i >= 0;i--) begin
        if(mantissa_sum[i] == 1)begin
            top_bits = i[7:0];
            break;
        end
    end

    //we then shift by the distance to the target
    shift_amount = 8'(TARGET_INDEX) - top_bits;
    //shifting the mantissa sum
    shifted_sum = 23'(mantissa_sum << shift_amount);
    normalized_fraction = shifted_sum[22:0];
    //normalizing exponent to keep the same number
    normalized_exp = larger_exp - shift_amount;

    if(top_bits > 8'(TARGET_INDEX)) begin
        shift_amount = top_bits - 8'(TARGET_INDEX);
        shifted_sum = 23'(mantissa_sum >> shift_amount);
        normalized_fraction = shifted_sum[22:0];
        normalized_exp = larger_exp + shift_amount;
    end

    sum = {final_sign, normalized_exp, normalized_fraction};
end

endmodule







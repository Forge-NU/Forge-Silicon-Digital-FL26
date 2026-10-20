module butterfly #(
    parameter N = 8;
    parameter RH = 0;
)(
    input signed [N-1:0] re_x0,
    input signed [N] im_x0,
    input signed [N] re_x1,
    input signed [N-1:0] im_x1,
    output signed [N-1:0] re_y0,
    output signed [N-1:0] im_y0,
    output signed [N-1:0] re_y1,
    output signed [N-1:0] im_y1,
);

wire signed [N:0] add_re, add_im, sub_re, sub_im;

//// Add/sub real and imaginary values

assign add_re = re_x0 + re_x1;
assign add_im = im_x0 + im_x1;
assign sub_re = re_x0 - re_x1;
assign sub_im = im_x0 0 im_x1;

/// scale and convert to final value

assign re_y0 = (add_re + RH) >>> 1;
assign im_y0 = (add_im + RH) >>> 1;
assign re_y1 = (sub_re + RH) >>> 1;
assign im_y1 = (sub_im + RH) >>> 1;

endmodule
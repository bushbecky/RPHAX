\m4_TLV_version 1d --fmtFlatSignals --bestsv --noline: tl-x.org
\SV
   // For exporting the kernel, use --bestsv --noline, and cut debug sigs statements from _gen file.

   // ==========================
   // Mandelbrot Set Calculation
   // ==========================

   // To relax Verilator compiler checking:
   /* verilator lint_off UNOPTFLAT */

   //TODO re-enable
   /* verilator lint_off WIDTH */
   /* verilator lint_off REALCVT */  // !!! SandPiper DEBUGSIGS BUG.


   // M4_PE_CNT engines compute pixel depths (in reading order) for a given image.
   // Image width must be a multiple of M4_PE_CNT or things could break.
   // PEs start at the same time.
   // Each may finish at different times, but all wait for the last to complete.
   // For each pixel calculation for each PE, computation proceeds through:
   //   o an "init" cycle where values are initialized based on pixel parameters
   //   o any number of "calc" cycles
   //   o a "done" cycle ("done_pulse")
   //   o any number of "wait" cycles ("done" but not "done_pulse")
   //   o (repeat)
   // Kernel has one active frame at a time, from the acceptance of config data to the transmission of the last data out.



   // Parameters:

   // Number of replicated Processing Elements
   m4_define_hier(M4_PE, 16)

   m4_define(M4_MAX_DEPTH, 8)

   // Fixed numbers (sign, int, fraction)
	// Fixed values are < 8.0.
	// There are two bit widths, normal and extended:
	// 	- Extended is used for X and Y coordinates calculation to avoid
	//      the accumulation of the rounding error as pixel width is added
   m4_define(M4_FIXED_UNSIGNED_WIDTH, 32)

	// Extended precision
   m4_define(M4_FIXED_EXT_PRECISION, 10)
	m4_define(M4_FIXED_EXT_UNSIGNED_WIDTH, m4_eval(M4_FIXED_UNSIGNED_WIDTH + M4_FIXED_EXT_PRECISION))

	// Data width for the incoming configuration data
	m4_define_vector(M4_CONFIG_DATA, 512)

	// Interleaving computation cycles
	m4_define(M4_ITER, 1)

	// PE pipeline depth
	m4_define(M4_PIPE_DEPTH, 2)
   // Latency between last pixel calculation and first of next pixels.
   m4_define(M4_PIX_LATENCY, 4)
   // Min latency between last pixels of one frame and the first of the next.
   m4_define(M4_FRAME_LATENCY, 5)

   // Constants and computed values:
   // Bit indices for fixed numbers
	// 	- [X:0] = integer portion
	// 	- [-1:Y] = fractional portion

	m4_define(M4_FIXED_INT_WIDTH, 3)
   m4_define(M4_FIXED_SIGN_BIT, M4_FIXED_INT_WIDTH)

	// Fixed point definition
   m4_define(M4_FIXED_FRAC_WIDTH, m4_eval(M4_FIXED_UNSIGNED_WIDTH - M4_FIXED_INT_WIDTH))
   m4_define(M4_FIXED_RANGE, ['M4_FIXED_SIGN_BIT:-M4_FIXED_FRAC_WIDTH'])
   m4_define(M4_FIXED_UNSIGNED_RANGE, ['m4_eval(M4_FIXED_SIGN_BIT-1):-M4_FIXED_FRAC_WIDTH'])

   // Extended fixed point definitions
	m4_define(M4_FIXED_EXT_FRAC_WIDTH, m4_eval(M4_FIXED_EXT_UNSIGNED_WIDTH - M4_FIXED_INT_WIDTH))
	m4_define(M4_FIXED_EXT_RANGE, ['M4_FIXED_SIGN_BIT:m4_eval(-(M4_FIXED_FRAC_WIDTH + M4_FIXED_EXT_PRECISION))'])
	m4_define(M4_FIXED_EXT_UNSIGNED_RANGE, ['m4_eval(M4_FIXED_SIGN_BIT-1):-M4_FIXED_EXT_FRAC_WIDTH'])
	//m4_makerchip_module
   // Zero extend to given width.
   `define ZX(val, width) {{1'b0{width-$bits(val)}}, val}


//TODO ifdef Makerchip



   module mandelbrot_kernel #(
     parameter integer C_DATA_WIDTH = 512 // Data width of both input and output data
   )
   (
     input wire                       axi_clk,
     input wire                       axi_reset_n,

     output wire                      s_axis_ready,
     input wire                       s_axis_valid,
     input wire  [C_DATA_WIDTH-1:0]   s_axis_data,

     input wire                       m_axis_ready,
     output wire                      m_axis_valid,
     output wire [C_DATA_WIDTH-1:0]   m_axis_data

   );
   //RPHAX Signal Names

   wire clk = axi_clk;
   wire reset = axi_reset_n; //Reset is positive logic ignore _n
   //Incoming data from DMA + ready -- AXI Stream Slave
   wire in_avail = s_axis_valid;
   wire [C_DATA_WIDTH-1:0] in_data = s_axis_data;
   wire in_ready = s_axis_ready;
   //Outgoing data to DMA + ready -- AXI Stream Master
   wire out_ready = m_axis_ready;
   wire out_avail = m_axis_valid;
   wire [C_DATA_WIDTH-1:0]   out_data = m_axis_data;




   logic frame_done;  // Instrumentation-only. Used to end simulation.

   function logic [M4_FIXED_RANGE] fixed_mul (input logic [M4_FIXED_RANGE] v1, v2);
      logic [M4_FIXED_INT_WIDTH-1:0] drop_bits;
      logic [M4_FIXED_FRAC_WIDTH-1:0] insignificant_bits;
      {fixed_mul[M4_FIXED_SIGN_BIT], drop_bits, fixed_mul[M4_FIXED_UNSIGNED_RANGE], insignificant_bits} =
         {v1[M4_FIXED_SIGN_BIT] ^ v2[M4_FIXED_SIGN_BIT], ({{M4_FIXED_UNSIGNED_WIDTH{1'b0}}, v1[M4_FIXED_UNSIGNED_RANGE]} * {{M4_FIXED_UNSIGNED_WIDTH{1'b0}}, v2[M4_FIXED_UNSIGNED_RANGE]})};
   endfunction;

   function logic [M4_FIXED_RANGE] fixed_add (input logic [M4_FIXED_RANGE] v1, v2, input logic sub);
      logic [M4_FIXED_RANGE] binary_v2;
      binary_v2 = fixed_to_binary(v1) +
                  fixed_to_binary({v2[M4_FIXED_SIGN_BIT] ^ sub, v2[M4_FIXED_UNSIGNED_RANGE]});
      fixed_add = binary_to_fixed(binary_v2);
   endfunction;

   function logic [M4_FIXED_RANGE] fixed_to_binary (input logic [M4_FIXED_RANGE] f);
      fixed_to_binary =
         f[M4_FIXED_SIGN_BIT]
            ? // Flip non-sign bits and add one. (Adding one is insignificant, so we save hardware and don't do it.)
              {1'b1, ~f[M4_FIXED_UNSIGNED_RANGE] /* + {{M4_FIXED_UNSIGNED_WIDTH-1{1'b0}}, 1'b1} */}
            : f;
   endfunction;

   function logic [M4_FIXED_RANGE] binary_to_fixed (input logic [M4_FIXED_RANGE] b);
      // The conversion is symmetric.
      binary_to_fixed = fixed_to_binary(b);
   endfunction;

   function logic [M4_FIXED_RANGE] real_to_fixed (input logic [63:0] b);
      real_to_fixed = {b[63], {1'b1, b[51:53-M4_FIXED_UNSIGNED_WIDTH]} >> (-(b[62:52] - 1023) + M4_FIXED_INT_WIDTH - 1)};
   endfunction;

   function logic [M4_FIXED_EXT_RANGE] real_to_ext_fixed (input logic [63:0] b);
      real_to_ext_fixed = {b[63], {1'b1, b[51:53-M4_FIXED_EXT_UNSIGNED_WIDTH]} >> (-(b[62:52] - 1023) + M4_FIXED_INT_WIDTH - 1)};
   endfunction;

\TLV

   |pipe
      
      // SV<->TLV for incoming data interface.
      @-2
         $reset = *reset;
      @-1
         *in_ready = $in_ready;
         $in_avail = *in_avail;
         $in_data[C_DATA_WIDTH-1:0] = *in_data;
         
      
      @-1
         $in_ready = ! >>1$frame_active;  // One frame at a time. Must be a one-cycle loop.
         $valid_config_data_in = $in_avail && $in_ready;
         {$config_data_bogus[63:0],
          $config_max_depth[63:0],
          $config_img_size_y[63:0],
          $config_img_size_x[63:0],
          $config_data_pix_y[63:0],
          $config_data_pix_x[63:0],
          $config_data_min_y[63:0],
          $config_data_min_x[63:0]} = $in_data;

         `BOGUS_USE($config_data_bogus)
      @0
         // Pulse for first calc of a new frame.
         $start_frame = $valid_config_data_in;  // Note, can assert only once the hardware is idle.
         $frame_active = $reset ? 1'b0 :
                         $start_frame ? 1'b1 :
                         >>m4_eval(M4_FRAME_LATENCY)$done_frame ? 0'b0 :  // (Falling edge alignment is arbitrary to meet timing.)
                         $RETAIN;

         // The computation is interleaved across M4_ITER cycles/strings

         // Val holds the valid condition for the computation
         // $val = $reset ? 0 : $start_frame || >>M4_ITER$val;
         //
         // ViewBox (fly-through)
         //
         // The view, given by upper-left corner coords and pixel x & y size.
         // It is initialized by the input FIFO
         $min_x[M4_FIXED_RANGE] = $reset ? '0 : $valid_config_data_in ? real_to_fixed($config_data_min_x) : $RETAIN;
         $min_y[M4_FIXED_RANGE] = $reset ? '0 : $valid_config_data_in ? real_to_fixed($config_data_min_y) : $RETAIN;
         $pix_x[M4_FIXED_EXT_RANGE] = $reset ? '0 : $valid_config_data_in ? real_to_ext_fixed($config_data_pix_x) : $RETAIN;
         $pix_y[M4_FIXED_EXT_RANGE] = $reset ? '0 : $valid_config_data_in ? real_to_ext_fixed($config_data_pix_y) : $RETAIN;

         // The size of the image. (M4_FIXED_RANGE???)
         $size_x[M4_FIXED_RANGE] = $reset ? '0 : $valid_config_data_in ? $config_img_size_x[31:0] : $RETAIN;
         $size_y[M4_FIXED_RANGE] = $reset ? '0 : $valid_config_data_in ? $config_img_size_y[31:0] : $RETAIN;

         $max_depth[31:0] = $reset ? '0 : $valid_config_data_in ? $config_max_depth[31:0] : $RETAIN;

         // Pulse for first valid calc cycle of new pixels.
         $init_pixels = $reset ? 1'b0 :
                                 ($start_frame || (>>M4_PIX_LATENCY$done_pixels && ! >>M4_PIX_LATENCY$done_frame));

      /M4_PE_HIER
         @0
            // Reset signal
            $reset = |pipe$reset;

            $init_pix = |pipe$init_pixels;
            
            // Assign next iteration values. Reset and last of frame resets values.
            $depth[31:0] =
               $reset       ? '0      :
               $init_pix    ? '0      :
                              >>M4_ITER$depth + 1;
            $pix_h[31:0] =
               $reset            ? #pe :
               |pipe$start_frame ? #pe :
               $init_pix         ? >>M4_ITER$last_h ? #pe :
                                                      >>M4_ITER$pix_h + M4_PE_CNT :
                                   >>M4_ITER$pix_h;
            $pix_v[31:0] =
               $reset                          ? '0 :
               ($init_pix && >>M4_ITER$last_h) ? >>M4_ITER$last_v ? '0 :
                                                                    >>M4_ITER$pix_v + 1 :
                                                 >>M4_ITER$pix_v;

         @1
            //
            // Screen render control
            //


            // Cycle over pixels (vertical (outermost) and horizontal) and depth (innermost).
            // When each wraps, increment the next.
            $last_h = $pix_h >= |pipe$size_x - M4_PE_CNT;  // TODO: If size_x is not a multiple of M4_PE_CNT, things will go awry!
            $last_v = $pix_v == |pipe$size_y - 1;

            //
            // Map pixels to x,y coords
            //


         @2
            // The coordinates of the pixel we are working on.
            // $xx = $init_pix ? $MinX + $PixX * $PixH : $RETAIN;  (in fixed-point)
            $xx_mul[M4_FIXED_EXT_UNSIGNED_RANGE] =
               (|pipe$pix_x[M4_FIXED_EXT_UNSIGNED_RANGE] * `ZX($pix_h, M4_FIXED_EXT_UNSIGNED_WIDTH));
            $xx[M4_FIXED_RANGE] =
               $init_pix ? fixed_add(|pipe$min_x[M4_FIXED_RANGE],
                                     {1'b0, $xx_mul[M4_FIXED_UNSIGNED_RANGE]},
                                     1'b0)
                         : >>M4_ITER$xx;
            // $yy = $init_pix ? $MinY + $PixY * $PixV : $RETAIN;  (in fixed-point)
            $yy_mul[M4_FIXED_EXT_UNSIGNED_RANGE] =
               (|pipe$pix_y[M4_FIXED_EXT_UNSIGNED_RANGE] * `ZX($pix_v, M4_FIXED_EXT_UNSIGNED_WIDTH));
            $yy[M4_FIXED_RANGE] =
               $init_pix ? fixed_add(|pipe$min_y[M4_FIXED_RANGE],
                                     {1'b0, $yy_mul[M4_FIXED_UNSIGNED_RANGE]},
                                     1'b0)
                         : >>M4_ITER$yy;

         @3
            //
            // Mandelbrot Calculation
            //
            // Mandelbrot algorithm:
            // a = 0.0
            // b = 0.0
            // depth = 0
            // for depth [0..max_depth] until diverged {  // one iteration per cycle
            //   a <= a*a - b*b + x
            //   b <= 2*a*b + y
            //   diverged = a*a + b*b >= 2.0*2.0
            // }
            $aa_sq[M4_FIXED_RANGE] = fixed_mul($aa, $aa);
            $bb_sq[M4_FIXED_RANGE] = fixed_mul($bb, $bb);
            $aa_sq_plus_bb_sq[M4_FIXED_RANGE] = fixed_add($aa_sq, $bb_sq, 1'b0);
            // Assert from $init_pix through $done_pix:
            $calc_valid = $reset             ? 1'b0 :
                          >>M4_ITER$init_pix ? 1'b1 :
                          >>M4_ITER$done_pix ? 1'b0 :
                                               >>M4_ITER$calc_valid;
            $done_pix =
                $reset ? 1'b0 :
                |pipe>>M4_ITER$out_valid ? 1'b0 :
                >>M4_ITER$done_pix       ? 1'b1 : // Hold value until sent (|pipe$out_valid). Must be a 1-iteration loop preventing back-to-back $out_valid.
                                           $calc_valid && (
                                              // a*a + b*b
                                              ({1'b0, $aa_sq_plus_bb_sq[M4_FIXED_UNSIGNED_RANGE]} >= real_to_fixed({1'b0, 1'b1, 9'b0, 1'b1, 52'b0})
                                              ) ||
                                              // This term catches some overflow cases w/ the multiply and allows fewer int bits to be used.
                                              // |a| >= 2.0 || |b| >= 2.0
                                              (|{$aa[M4_FIXED_SIGN_BIT-1:M4_FIXED_SIGN_BIT-M4_FIXED_INT_WIDTH+1],
                                                 $bb[M4_FIXED_SIGN_BIT-1:M4_FIXED_SIGN_BIT-M4_FIXED_INT_WIDTH+1]}
                                              ) ||
                                              ($depth == |pipe$max_depth)
                                           );
            //+$not_done = ! $done_pix;

            //?$not_done
            $aa_sq_minus_bb_sq[M4_FIXED_RANGE] = fixed_add($aa_sq, $bb_sq, 1'b1);
            <<M4_ITER$aa[M4_FIXED_RANGE] = $init_pix ? $xx : fixed_add($aa_sq_minus_bb_sq, $xx, 1'b0);
            $aa_times_bb[M4_FIXED_RANGE] = fixed_mul($aa, $bb);
            $aa_times_bb_times_2[M4_FIXED_RANGE] = {$aa_times_bb[M4_FIXED_SIGN_BIT], $aa_times_bb[M4_FIXED_UNSIGNED_RANGE] << 1};
            <<M4_ITER$bb[M4_FIXED_RANGE] = $init_pix ? $yy : fixed_add($aa_times_bb_times_2, $yy, 1'b0);

            $done_pix_pulse = $done_pix & ! >>M4_ITER$done_pix;
            $depth_out[31:0] = $done_pix_pulse ? $depth : $RETAIN;
      @4
         $all_pix_done = $reset ? '0 : & /pe[*]$done_pix && *out_ready;
         //$all_pix_done_pulse = $all_pix_done & ! >>1$all_pix_done;
         $out_data[C_DATA_WIDTH-1:0] = /pe[*]$depth_out;
         $out_avail = $all_pix_done;
         $out_valid = $out_avail && $out_ready;
         $done_pixels = $out_valid;
         $done_frame = $done_pixels && /pe[*]$last_h & /pe[*]$last_v;
      
      // SV<->TLV for outgoing data interface.
      @4
         *out_data = $out_data;
         *out_avail = $out_avail;
         $out_ready = *out_ready;
      
      // Testbench control.
      @10
         *frame_done = $done_frame;
         

\SV
   endmodule
